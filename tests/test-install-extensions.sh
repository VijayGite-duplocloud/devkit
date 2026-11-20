#!/usr/bin/env bash
# Checks scripts/install-extensions.sh (DUPLOAI-4813): reads the registry catalog once, skips ids that are not in it,
# picks the semver-highest stable version (or the pinned id@version), skips a version /versions already reports as
# current, and otherwise POSTs the install with pin:false — surfacing the server's reason on every failure.
#
# Runs the script from a temp copy of the kit with a stub `curl` first on PATH, so it never reaches a real studio.
# The stub serves $STUB/catalog.json, $STUB/versions-<id>.json (+ .code) and $STUB/install.body (+ install.code),
# and logs "<METHOD> <URL> <BODY>" per call to $STUB/curl.log.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
PASS=0; FAIL=0
t()   { printf '  %s … ' "$1"; }
ok()  { echo "ok"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

command -v python3 >/dev/null 2>&1 || { echo "skipped: needs python3"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
KIT="$TMP/kit"; STUB="$TMP/stub"
mkdir -p "$KIT/scripts" "$TMP/bin" "$STUB"
cp scripts/install-extensions.sh scripts/_target.sh "$KIT/scripts/" 2>/dev/null
printf 'DUPLO_ADMIN_TOKEN=fixture\n' > "$KIT/.env"
API=http://localhost:60021/v1/aiservicedesk/admin

cat > "$TMP/bin/curl" <<'SH'
#!/usr/bin/env bash
method=GET; url=""; body=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift ;;
    --data|-d) body="$2"; shift ;;
    http*) url="$1" ;;
  esac
  shift
done
echo "$method $url $body" >> "$STUB/curl.log"
reply() { printf '%s\n%s' "$1" "$2"; }
case "$url" in
  */extension-registry/catalog)
    if [ -f "$STUB/catalog.json" ]; then reply "$(cat "$STUB/catalog.json")" 200; else reply oops 500; fi ;;
  */admin/extensions/*/versions)
    id="${url%/versions}"; id="${id##*/}"
    if [ -f "$STUB/versions-$id.json" ]; then
      reply "$(cat "$STUB/versions-$id.json")" "$(cat "$STUB/versions-$id.code" 2>/dev/null || echo 200)"
    else reply '{"message":"not found"}' 404; fi ;;
  */extension-registry/install)
    reply "$(cat "$STUB/install.body" 2>/dev/null || echo '{}')" "$(cat "$STUB/install.code" 2>/dev/null || echo 200)" ;;
  *) exit 7 ;;
esac
SH
chmod +x "$TMP/bin/curl"

# catalog "id=v1,v2" … → $STUB/catalog.json; "id=" gives that id an empty versions array.
catalog() {
  python3 - "$STUB/catalog.json" "$@" <<'PY'
import json, sys
exts = []
for spec in sys.argv[2:]:
    i, _, vs = spec.partition("=")
    exts.append({"id": i, "versions": [{"version": v, "name": i, "changelog": ""} for v in vs.split(",") if v]})
json.dump({"extensions": exts, "marks": []}, open(sys.argv[1], "w"))
PY
}
# reset → the default fixture: X in the catalog at 1.2.0, 1.10.0, 1.9.3 (that order), nothing installed.
reset() { rm -f "$STUB"/*; catalog "com.example.x=1.2.0,1.10.0,1.9.3"; }

# run ARGS… → runs the copy with only the fixture .env and the stub; stdout in $OUT, stderr in $ERR, exit in $RC.
run() {
  : > "$STUB/curl.log"
  OUT="$(cd "$KIT" && env -u DUPLO_TARGET -u DUPLO_HOST -u DUPLO_TOKEN -u DUPLO_BASE -u DUPLO_ADMIN_TOKEN \
    -u DUPLO_ENV_FILE PATH="$TMP/bin:$PATH" STUB="$STUB" ./scripts/install-extensions.sh "$@" 2>"$TMP/err")"
  RC=$?
  ERR="$(cat "$TMP/err")"
}
# installs → one normalised JSON body per install POST, in call order.
installs() {
  sed -n 's#^POST [^ ]*/extension-registry/install ##p' "$STUB/curl.log" \
    | python3 -c 'import json,sys
for l in sys.stdin:
    if l.strip(): print(json.dumps(json.loads(l), sort_keys=True, separators=(",", ":")))'
}
# installed_versions → just the version of each install POST, one per line.
installed_versions() { installs | python3 -c 'import json,sys
for l in sys.stdin: print(json.loads(l)["version"])'; }
has()   { grep -qF -- "$2" <<<"$1"; }
calls() { awk '{print $1, $2}' "$STUB/curl.log"; }

echo "install-extensions.sh:"

reset; run com.example.x
t "picks_semver_highest: installs 1.10.0 over 1.9.3 and 1.2.0, with pin:false"
if [ "$RC" = 0 ] && [ "$(installs)" = '{"extensionId":"com.example.x","pin":false,"version":"1.10.0"}' ] \
   && has "$OUT" "    ✔ com.example.x 1.10.0 — installed"; then ok; else bad "rc=$RC installs=$(installs) out=$OUT err=$ERR"; fi

t "pin_is_json_false: pin is a JSON boolean, not a string"
if grep -q '"pin": false' "$STUB/curl.log"; then ok; else bad "$(cat "$STUB/curl.log")"; fi

t "call_sequence: catalog, then versions, then install — and no catalog refresh"
expected="GET $API/extension-registry/catalog
GET $API/extensions/com.example.x/versions
POST $API/extension-registry/install"
if [ "$(calls)" = "$expected" ] && ! grep -q refresh "$STUB/curl.log"; then ok; else bad "$(calls)"; fi

reset; catalog "com.example.x=1.0.0" "com.example.y=2.0.0"; run com.example.x com.example.y
t "catalog_read_once: two ids, one catalog GET"
if [ "$(grep -c '/extension-registry/catalog' "$STUB/curl.log")" = 1 ] && [ "$(installed_versions | tr '\n' ' ')" = "1.0.0 2.0.0 " ]
then ok; else bad "$(calls)"; fi

reset; echo '[{"version":"1.10.0","isCurrent":true}]' > "$STUB/versions-com.example.x.json"; run com.example.x
t "current_version_skipped: no install when the chosen version is already current"
if [ "$RC" = 0 ] && ! grep -q /install "$STUB/curl.log" && has "$OUT" "    ✔ com.example.x 1.10.0 — already installed"
then ok; else bad "rc=$RC out=$OUT log=$(calls)"; fi

reset; echo '[{"version":"1.9.3","isCurrent":true},{"version":"1.2.0","isCurrent":false}]' > "$STUB/versions-com.example.x.json"
run com.example.x
t "older_current_upgraded: current 1.9.3 → installs 1.10.0"
if [ "$RC" = 0 ] && [ "$(installed_versions)" = 1.10.0 ]; then ok; else bad "rc=$RC installs=$(installs)"; fi

reset; catalog "com.example.x=2.0.0-rc.1,1.10.0"; run com.example.x
t "stable_beats_prerelease: 1.10.0 over 2.0.0-rc.1"
if [ "$(installed_versions)" = 1.10.0 ]; then ok; else bad "installs=$(installs) err=$ERR"; fi

reset; catalog "com.example.x=2.0.0-rc.1,2.0.0-rc.10,2.0.0-rc.2"; run com.example.x
t "prerelease_only: highest pre-release, compared numerically (rc.10 > rc.2)"
if [ "$(installed_versions)" = 2.0.0-rc.10 ]; then ok; else bad "installs=$(installs) err=$ERR"; fi

reset; run com.example.x@1.2.0
t "pinned_version_present: id@1.2.0 installs 1.2.0, not the latest"
if [ "$RC" = 0 ] && [ "$(installed_versions)" = 1.2.0 ]; then ok; else bad "rc=$RC installs=$(installs) err=$ERR"; fi

reset; run com.example.x@9.9.9
t "pinned_version_absent: fails, lists what is available highest first, calls nothing else"
if [ "$RC" = 1 ] && has "$ERR" "    ✗ com.example.x@9.9.9 — version not in the catalog (available: 1.10.0, 1.9.3, 1.2.0)" \
   && ! grep -q /versions "$STUB/curl.log" && ! grep -q /install "$STUB/curl.log"; then ok; else bad "rc=$RC err=$ERR log=$(calls)"; fi

reset; run com.example.y com.example.x
t "unknown_id_skipped: an id not in the catalog is skipped, the next id still installs, exit 0"
if [ "$RC" = 0 ] && has "$OUT" "    ↷ com.example.y — not in the extension catalog, skipped" \
   && [ "$(installed_versions)" = 1.10.0 ] && ! grep -q com.example.y "$STUB/curl.log"; then ok
else bad "rc=$RC out=$OUT err=$ERR log=$(calls)"; fi

reset; catalog "com.example.x="; run com.example.x
t "empty_versions_skipped: an id with no versions is skipped like a missing one"
if [ "$RC" = 0 ] && has "$OUT" "    ↷ com.example.x — not in the extension catalog, skipped" \
   && ! grep -q /install "$STUB/curl.log" && ! has "$OUT$ERR" Traceback; then ok; else bad "rc=$RC out=$OUT err=$ERR"; fi

reset; rm -f "$STUB/catalog.json"; run com.example.x
t "catalog_unreachable: exit 1 with the server's reason, nothing after the catalog GET"
if [ "$RC" = 1 ] && has "$ERR" "    ✗ could not read the extension catalog: HTTP 500: oops" \
   && [ "$(wc -l < "$STUB/curl.log" | tr -d ' ')" = 1 ]; then ok; else bad "rc=$RC err=$ERR log=$(calls)"; fi

reset; echo oops > "$STUB/versions-com.example.x.json"; echo 500 > "$STUB/versions-com.example.x.code"; run com.example.x
t "versions_http_error: a /versions 500 is an error, not a blind install"
if [ "$RC" = 1 ] && has "$ERR" "    ✗ com.example.x — could not read installed versions: HTTP 500: oops" \
   && ! grep -q /install "$STUB/curl.log"; then ok; else bad "rc=$RC err=$ERR log=$(calls)"; fi

reset; echo 400 > "$STUB/install.code"
echo '{"message":"license has expired","code":"license_limit_exceeded"}' > "$STUB/install.body"; run com.example.x
t "install_http_error_message: the studio's message and code reach the user"
if [ "$RC" = 1 ] && has "$ERR" "    ✗ com.example.x 1.10.0 — install failed: HTTP 400: license has expired (license_limit_exceeded)"
then ok; else bad "rc=$RC err=$ERR"; fi

reset; echo 502 > "$STUB/install.code"; echo '<html>Bad Gateway</html>' > "$STUB/install.body"; run com.example.x
t "install_non_json_error: a non-JSON body is shown raw, no traceback"
if [ "$RC" = 1 ] && has "$ERR" "install failed: HTTP 502: <html>Bad Gateway</html>" && ! has "$OUT$ERR" Traceback
then ok; else bad "rc=$RC err=$ERR"; fi

reset; run '../etc' '..' com.example.x
t "invalid_id_rejected: ids that could escape the URL path are refused and never sent"
if [ "$RC" = 1 ] && has "$ERR" "    ✗ '../etc' — invalid extension id" && has "$ERR" "    ✗ '..' — invalid extension id" \
   && ! grep -qE 'etc|/extensions/\.\./' "$STUB/curl.log" && [ "$(installed_versions)" = 1.10.0 ]; then ok
else bad "rc=$RC err=$ERR log=$(calls)"; fi

reset; run
t "no_args_usage: exit 2 with usage on stderr"
if [ "$RC" = 2 ] && [ "${ERR%%:*}" = Usage ]; then ok; else bad "rc=$RC err=$ERR"; fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
