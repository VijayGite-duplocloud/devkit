#!/usr/bin/env bash
# Install extensions from the studio's extension registry by id, at the newest version the catalog offers.
#
# WHY: a fresh dev kit should come up with the agents people start from (DUPLOAI-4813: the Cloud Deployment
# Agent first) already installed, rather than leaving every developer to find them in the registry by hand.
# run.sh calls this with its DEVKIT_EXTENSIONS list; it also works on its own, against a local or remote target.
#
# For each id: look it up in the registry catalog (read once). An id the catalog doesn't list, or lists with no
# versions, is skipped — not an error. Otherwise pick the semver-highest stable version (the highest
# pre-release only when there is no stable one), or exactly the version given as id@version.
# Then ask /extensions/{id}/versions what is installed: if that version is already current, do nothing;
# else POST the install with pin:false, so the extension still follows later registry updates.
#
# Idempotent: re-running installs nothing that is already current. Every failure prints the server's own reason
# and the remaining ids are still processed.
#
# Usage: ./scripts/install-extensions.sh <extension-id>[@<version>] [...]
# Exit:  0 every id installed, already current or skipped as not in the catalog
#        1 at least one id failed, no token, or the catalog could not be read
#        2 usage
set -euo pipefail
cd "$(dirname "$0")/.."

[ $# -gt 0 ] || { echo "Usage: $0 <extension-id>[@<version>] [...]" >&2; exit 2; }

source "$(dirname "$0")/_target.sh"   # → BASE_URL + TOKEN from .env per DUPLO_TARGET
[ -n "$TOKEN" ] || { echo "No token resolved — set DUPLO_ADMIN_TOKEN (local) or DUPLO_TOKEN (remote) in .env." >&2; exit 1; }
ADMIN="$BASE_URL/v1/aiservicedesk/admin"

# api METHOD URL [BODY] → the response body, then a last line holding the HTTP status (000: no response at all).
# Never curl -f: on a 4xx/5xx the body is the only place the studio says why (see scripts/_studio_api.sh).
api() {
  local args=(-sS --max-time 30 -w '\n%{http_code}' -X "$1" "$2" -H "Authorization: Bearer $TOKEN")
  [ $# -lt 3 ] || args+=(-H "Content-Type: application/json" --data "$3")
  curl "${args[@]}" 2>/dev/null || printf '\n000'
}
status_of() { printf '%s' "${1##*$'\n'}"; }   # last line of an api() reply
body_of()   { printf '%s' "${1%$'\n'*}"; }    # everything before it

# err_msg BODY → the studio's reason: message + errors + " (code)" for a JSON body, else the raw text.
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
    if d.get("code"): msg += " (%s)" % d["code"]
print(msg or raw.strip() or "<empty body>")'
}

# ── validate every argument before calling anything ─────────────────────────────────────────────
# The id goes into a URL path, so it must start alphanumeric and hold only [A-Za-z0-9._-] — no '/', no '..'.
FAILED=0; IDS=(); WANTS=()
for arg in "$@"; do
  id="${arg%%@*}"; want=""
  [ "$id" = "$arg" ] || want="${arg#*@}"
  if [[ "$id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] && { [ "$id" = "$arg" ] || [ -n "$want" ]; }; then
    IDS+=("$id"); WANTS+=("$want")
  else
    echo "    ✗ '$arg' — invalid extension id" >&2; FAILED=1
  fi
done
[ ${#IDS[@]} -gt 0 ] || exit 1

# ── the registry catalog, read once ─────────────────────────────────────────────────────────────
REPLY_="$(api GET "$ADMIN/extension-registry/catalog")"
CODE="$(status_of "$REPLY_")"; CATALOG="$(body_of "$REPLY_")"
if [[ "$CODE" != 2* ]] || ! printf '%s' "$CATALOG" | python3 -c '
import sys, json
d = json.load(sys.stdin)
raise SystemExit(0 if isinstance(d, dict) and isinstance(d.get("extensions"), list) else 1)' 2>/dev/null; then
  echo "    ✗ could not read the extension catalog: HTTP $CODE: $(err_msg "$CATALOG")" >&2
  exit 1
fi

# pick_version ID WANT → "ok <version>" | "missing" | "absent <v1, v2, …>" (highest first), from $CATALOG.
pick_version() {
  printf '%s' "$CATALOG" | ID="$1" WANT="$2" python3 -c '
import sys, json, os
def key(v):  # semver-ish: numeric core, stable above its pre-releases, pre-release parts compared numerically
    core, _, pre = v.partition("-")
    nums = tuple(int(p) if p.isdigit() else 0 for p in core.split("."))
    pre_key = tuple((0, int(p), "") if p.isdigit() else (1, 0, p) for p in pre.split(".")) if pre else ()
    return (nums, 0 if pre else 1, pre_key)
ext = next((e for e in json.load(sys.stdin)["extensions"] if isinstance(e, dict) and e.get("id") == os.environ["ID"]), None)
vs = [v["version"] for v in (ext or {}).get("versions") or [] if isinstance(v, dict) and v.get("version")]
want = os.environ["WANT"]
if not vs: print("missing")
elif want: print("ok " + want if want in vs else "absent " + ", ".join(sorted(vs, key=key, reverse=True)))
else: print("ok " + max([v for v in vs if "-" not in v] or vs, key=key))'
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

# ── per id: pick the version, skip it if current, else install ──────────────────────────────────
for i in "${!IDS[@]}"; do
  id="${IDS[$i]}"; want="${WANTS[$i]}"
  pick="$(pick_version "$id" "$want")" || pick=""
  case "$pick" in
    "ok "?*) ver="${pick#ok }" ;;
    missing) echo "    ↷ $id — not in the extension catalog, skipped"; continue ;;
    absent*) echo "    ✗ $id@$want — version not in the catalog (available: ${pick#absent })" >&2; FAILED=1; continue ;;
    *)       echo "    ✗ $id — could not read its catalog entry" >&2; FAILED=1; continue ;;
  esac

  REPLY_="$(api GET "$ADMIN/extensions/$id/versions")"; CODE="$(status_of "$REPLY_")"; BODY="$(body_of "$REPLY_")"
  if [[ "$CODE" == 2* ]] && is_current "$BODY" "$ver"; then
    echo "    ✔ $id $ver — already installed"; continue
  elif [[ "$CODE" != 2* && "$CODE" != 404 ]]; then
    echo "    ✗ $id — could not read installed versions: HTTP $CODE: $(err_msg "$BODY")" >&2; FAILED=1; continue
  fi

  REQ="$(ID="$id" V="$ver" python3 -c 'import json,os;print(json.dumps({"extensionId":os.environ["ID"],"version":os.environ["V"],"pin":False}))')"
  REPLY_="$(api POST "$ADMIN/extension-registry/install" "$REQ")"; CODE="$(status_of "$REPLY_")"
  if [[ "$CODE" == 2* ]]; then
    echo "    ✔ $id $ver — installed"
  else
    echo "    ✗ $id $ver — install failed: HTTP $CODE: $(err_msg "$(body_of "$REPLY_")")" >&2; FAILED=1
  fi
done
exit "$FAILED"
