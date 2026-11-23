#!/usr/bin/env bash
# Install extensions from the studio's extension registry by manifest id (e.g. com.duplocloud.demo-cloud-deployment).
#
# WHY: a fresh dev kit should come up with the agents people start from (DUPLOAI-4813: the Cloud Deployment
# Agent first) already installed, rather than leaving every developer to find them in the registry by hand.
# run.sh calls this with its DEVKIT_EXTENSIONS list; it also works on its own, against a local or remote target.
#
# Each argument is a MANIFEST id — the license catalog's manifest_id, which the installer keys every catalog entry
# and install request on. Never the agent's UUID (the installer only reports installs to the license server with
# it; sent as extensionId it matches nothing and fails not-entitled) and never the catalog row's `id`, the
# console's renameable display slug. Catalog rows are matched on manifestId, falling back to id.
#
# Flow (DUPLOAI-4813, per the ticket's trace of backend → installer):
#   1. POST …/extension-registry/catalog/refresh, so the installer's catalog isn't stale right after a new license.
#      A failed refresh is a warning: the cached catalog is still read.
#   2. GET …/extension-registry/catalog, once. Per id:
#        - not in the catalog, or not licensed for this install → skipped (not an error)
#        - pinned by an admin (a pin, or a rollback, which always pins) → left alone: an unpinned install clears it
#        - an install request the installer is still working on → left alone, not requested twice
#        - the version is the one the installer's mark offers: without a pin it accepts no other (409
#          version-not-offered). No offered version → skipped, since the license most likely doesn't list it.
#   3. GET …/extensions/{id}/versions: already current → nothing to do.
#   4. POST …/extension-registry/install {"extensionId","version","pin":false}. The installer works in the
#      background: 202 (accepted) or 200 (a request was already pending) both carry a requestId and state.
#   5. Poll the catalog's requests[] for that request until it is done (installed), failed or backed-out (an
#      error, with the installer's reason — e.g. not-entitled when the license doesn't list it), or until
#      EXT_INSTALL_TIMEOUT seconds (default 300) pass, checking every EXT_INSTALL_POLL seconds (default 5).
#
# Idempotent: re-running installs nothing that is current, pinned or in progress. Every failure prints the server's
# own reason and the remaining ids are still processed.
#
# Usage: ./scripts/install-extensions.sh <manifest-id> [...]
# Exit:  0 every id installed, already current, or skipped
#        1 at least one id failed or timed out, no token, or the catalog could not be read
#        2 usage
set -euo pipefail
cd "$(dirname "$0")/.."

[ $# -gt 0 ] || { echo "Usage: $0 <manifest-id> [...]" >&2; exit 2; }

source "$(dirname "$0")/_target.sh"   # → BASE_URL + TOKEN from .env per DUPLO_TARGET
[ -n "$TOKEN" ] || { echo "No token resolved — set DUPLO_ADMIN_TOKEN (local) or DUPLO_TOKEN (remote) in .env." >&2; exit 1; }
ADMIN="$BASE_URL/v1/aiservicedesk/admin"
TIMEOUT="${EXT_INSTALL_TIMEOUT:-300}"; [[ "$TIMEOUT" =~ ^[0-9]+$ ]] || TIMEOUT=300
POLL="${EXT_INSTALL_POLL:-5}";        [[ "$POLL" =~ ^[0-9]+$ ]] || POLL=5

# api METHOD URL [BODY] → the response body, then a last line holding the HTTP status (000: no response at all).
# Never curl -f: on a 4xx/5xx the body is the only place the studio says why (see scripts/_studio_api.sh).
api() {
  local args=(-sS --max-time 30 -w '\n%{http_code}' -X "$1" "$2" -H "Authorization: Bearer $TOKEN")
  [ $# -lt 3 ] || args+=(-H "Content-Type: application/json" --data "$3")
  curl "${args[@]}" 2>/dev/null || printf '\n000'
}
status_of() { printf '%s' "${1##*$'\n'}"; }   # last line of an api() reply
body_of()   { printf '%s' "${1%$'\n'*}"; }    # everything before it

# err_msg BODY → the server's reason: message + errors, tagged with its code or reason slug; else the raw text.
err_msg() {
  printf '%s' "$1" | python3 -c '
import sys, json
raw = sys.stdin.read()
try: d = json.loads(raw)
except Exception: d = None
msg = ""
if isinstance(d, dict):
    errs = d.get("errors")
    if isinstance(errs, (list, dict)): errs = json.dumps(errs)
    msg = " ".join(str(x) for x in (d.get("message"), errs) if x)
    tag = d.get("code") or d.get("reason")
    if tag: msg = "%s (%s)" % (msg, tag) if msg else str(tag)
print(msg or raw.strip() or "<empty body>")'
}

# ── validate every argument before calling anything ─────────────────────────────────────────────
# The id goes into a URL path, so it must start alphanumeric and hold only [A-Za-z0-9._-] — no '/', no '..', and
# no '@version': without a pin the installer only takes the version it offers, so a list entry can't choose one.
FAILED=0; IDS=()
for arg in "$@"; do
  if [[ "$arg" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then IDS+=("$arg")
  else echo "    ✗ '$arg' — invalid extension id" >&2; FAILED=1
  fi
done
[ ${#IDS[@]} -gt 0 ] || exit 1

# ── refresh, then read the registry catalog once ────────────────────────────────────────────────
REPLY_="$(api POST "$ADMIN/extension-registry/catalog/refresh")"; CODE="$(status_of "$REPLY_")"
[[ "$CODE" == 2* ]] || echo "    ! could not refresh the extension catalog: HTTP $CODE: $(err_msg "$(body_of "$REPLY_")") — using the cached one" >&2

# A license problem still answers 200, with libraryState saying which and no extensions: that must read as an
# error, never as "every id is missing".
REPLY_="$(api GET "$ADMIN/extension-registry/catalog")"
CODE="$(status_of "$REPLY_")"; CATALOG="$(body_of "$REPLY_")"
STATE="bad"
[[ "$CODE" != 2* ]] || STATE="$(printf '%s' "$CATALOG" | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: d = None
if not isinstance(d, dict) or not isinstance(d.get("extensions"), list): print("bad")
else: print(d.get("libraryState") or "ok")' 2>/dev/null)" || STATE="bad"
case "$STATE" in
  ok) ;;
  bad) echo "    ✗ could not read the extension catalog: HTTP $CODE: $(err_msg "$CATALOG")" >&2; exit 1 ;;
  *)
    case "$STATE" in
      missing)     why="no license is configured" ;;
      invalid)     why="the license server refused this install's license" ;;
      unavailable) why="the license server could not be reached" ;;
      *)           why="see the Extension Library page" ;;
    esac
    echo "    ✗ could not read the extension catalog: library state \"$STATE\" ($why)" >&2; exit 1 ;;
esac

# plan_install ID → one line from $CATALOG: "ok <version>" | "missing" | "unlicensed" | "pinned <version>" |
# "busy <state>" | "blocked <reason>" | "nooffer".
plan_install() {
  printf '%s' "$CATALOG" | ID="$1" python3 -c '
import sys, json, os
def rows(name): return [r for r in c.get(name) or [] if isinstance(r, dict)]
c = json.load(sys.stdin); id_ = os.environ["ID"]
ext = next((e for e in rows("extensions") if (e.get("manifestId") or e.get("id")) == id_), None)
mark = next((m for m in rows("marks") if m.get("id") == id_), None) or {}
busy = next((r for r in rows("requests") if r.get("id") == id_ and r.get("state") not in ("done", "backed-out", "failed")), None)
if ext is None: out = "missing"
elif ext.get("licensed") is False: out = "unlicensed"
elif mark.get("pinnedVersion"): out = "pinned " + mark["pinnedVersion"]
elif busy: out = "busy " + (busy.get("state") or "pending")
elif mark.get("version"): out = "ok " + mark["version"]
elif mark.get("reason"): out = "blocked " + mark["reason"]
else: out = "nooffer"
print(out)'
}

# is_current BODY VERSION → rc 0 when the /versions reply marks VERSION as the current one.
is_current() {
  printf '%s' "$1" | V="$2" python3 -c '
import sys, json, os
try: d = json.load(sys.stdin)
except Exception: d = []
cur = any(isinstance(e, dict) and e.get("isCurrent") and e.get("version") == os.environ["V"] for e in (d if isinstance(d, list) else []))
raise SystemExit(0 if cur else 1)'
}

# request_id BODY → the requestId an install reply carries, or nothing.
request_id() {
  printf '%s' "$1" | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: d = None
print((d.get("requestId") or d.get("request_id") or "") if isinstance(d, dict) else "")' 2>/dev/null || true
}

# request_state CATALOG ID VERSION RID → "<state> <reason[: detail]>" for the request (by RID, else the latest one
# for ID at VERSION), or nothing when the catalog doesn't list it (yet).
request_state() {
  printf '%s' "$1" | ID="$2" V="$3" RID="$4" python3 -c '
import sys, json, os
try: c = json.load(sys.stdin)
except Exception: c = None
rs = [r for r in (c.get("requests") or [] if isinstance(c, dict) else []) if isinstance(r, dict)]
rid = os.environ["RID"]
m = [r for r in rs if r.get("requestId") == rid] if rid else \
    [r for r in rs if r.get("id") == os.environ["ID"] and r.get("version") == os.environ["V"]]
if m:
    r = m[-1]
    why = ": ".join(str(x) for x in (r.get("reason"), r.get("detail")) if x)
    print(((r.get("state") or "pending") + " " + why).strip())' 2>/dev/null || true
}

# wait_for_install ID VERSION RID → polls the catalog until the request is done (rc 0), or failed, backed out or
# still running at the deadline (rc 1, reason on stderr).
wait_for_install() {
  local id="$1" ver="$2" rid="$3" deadline=$((SECONDS + TIMEOUT)) last="accepted" got state why
  while :; do
    got="$(api GET "$ADMIN/extension-registry/catalog")"
    if [[ "$(status_of "$got")" == 2* ]]; then
      state="$(request_state "$(body_of "$got")" "$id" "$ver" "$rid")"
      why=""; [ "${state#* }" = "$state" ] || why="${state#* }"; state="${state%% *}"
      case "$state" in
        done) echo "    ✔ $id $ver — installed"; return 0 ;;
        failed|backed-out)
          echo "    ✗ $id $ver — install failed: $state${why:+ ($why)}" >&2; return 1 ;;
        "") ;;
        *) last="$state" ;;
      esac
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "    ✗ $id $ver — still $last after ${TIMEOUT}s (EXT_INSTALL_TIMEOUT); check the Extension Library page" >&2
      return 1
    fi
    sleep "$POLL"
  done
}

# ── per id: decide, skip if current, else install and wait for the installer ────────────────────
for id in "${IDS[@]}"; do
  pick="$(plan_install "$id")" || pick=""
  case "$pick" in
    "ok "?*)     ver="${pick#ok }" ;;
    missing)     echo "    ↷ $id — not in the extension catalog, skipped"; continue ;;
    unlicensed)  echo "    ↷ $id — not licensed for this install, skipped"; continue ;;
    nooffer)     echo "    ↷ $id — the installer offers no version (does the license list it?), skipped"; continue ;;
    "pinned "*)  echo "    ↷ $id — pinned at ${pick#pinned }, left alone"; continue ;;
    "busy "*)    echo "    ↷ $id — an install is already in progress (${pick#busy })"; continue ;;
    "blocked "*) echo "    ✗ $id — the installer can't install it here: ${pick#blocked }" >&2; FAILED=1; continue ;;
    *)           echo "    ✗ $id — could not read its catalog entry" >&2; FAILED=1; continue ;;
  esac

  REPLY_="$(api GET "$ADMIN/extensions/$id/versions")"; CODE="$(status_of "$REPLY_")"; BODY="$(body_of "$REPLY_")"
  if [[ "$CODE" == 2* ]] && is_current "$BODY" "$ver"; then
    echo "    ✔ $id $ver — already installed"; continue
  elif [[ "$CODE" != 2* && "$CODE" != 404 ]]; then
    echo "    ✗ $id — could not read installed versions: HTTP $CODE: $(err_msg "$BODY")" >&2; FAILED=1; continue
  fi

  REQ="$(ID="$id" V="$ver" python3 -c 'import json,os;print(json.dumps({"extensionId":os.environ["ID"],"version":os.environ["V"],"pin":False}))')"
  REPLY_="$(api POST "$ADMIN/extension-registry/install" "$REQ")"; CODE="$(status_of "$REPLY_")"
  if [[ "$CODE" != 2* ]]; then
    echo "    ✗ $id $ver — install failed: HTTP $CODE: $(err_msg "$(body_of "$REPLY_")")" >&2; FAILED=1; continue
  fi
  # 202: accepted; 200: a request for it was already pending. Neither means installed yet.
  echo "    … $id $ver — install requested (HTTP $CODE), waiting for the installer"
  wait_for_install "$id" "$ver" "$(request_id "$(body_of "$REPLY_")")" || FAILED=1
done
exit "$FAILED"
