#!/usr/bin/env bash
# Checks run.sh's admin login before minting the permanent API token (DUPLOAI-5693).
#
# Why this exists: run.sh runs under `set -euo pipefail`, and the login used to be
#   JWT="$(curl -fsS … PasswordLogin … | python3 -c '…["access_token"]' 2>/dev/null)"
# A response without access_token — e.g. 200 {"mustChangePassword":true,"challengeCode":…} for an admin
# password shorter than the portal policy — made python3 raise KeyError, pipefail failed the assignment,
# and set -e killed the script *before* the "Login failed" line could print: setup just stopped after
# "==> Minting permanent admin API token…". Any other login failure (401, timeout, HTML error page) did
# the same.
#
# This extracts parse_login_resp(), report_login_failure() and the login block itself straight from
# run.sh (not a copy), runs the block under `set -euo pipefail` with curl stubbed, and checks that every
# failure shape ends in a message and exit 1 — never a silent exit — and that a good response yields the token.
# Nothing here starts the stack or touches .env.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
PASS=0; FAIL=0
t()   { printf '  %s … ' "$1"; }
ok()  { echo "ok"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# run.sh calls python3; on a Windows box python3 may be the Store stub while `python` works.
if ! python3 -c 'print(1)' >/dev/null 2>&1; then
  if python -c 'print(1)' >/dev/null 2>&1; then python3() { python "$@"; }; export -f python3
  else echo "SKIP: no working python3/python on PATH"; exit 0; fi
fi

echo "run.sh admin login wiring:"

t "run.sh is syntactically valid and defines parse_login_resp and report_login_failure"
if bash -n run.sh 2>/dev/null && grep -q '^parse_login_resp() {' run.sh && grep -q '^report_login_failure() {' run.sh; then ok
else bad "missing/syntax error"; exit 1; fi

t "the login no longer indexes [\"access_token\"] directly (KeyError under pipefail = silent exit)"
if ! grep -q 'json.load(sys.stdin)\["access_token"\]' run.sh; then ok; else bad "direct [\"access_token\"] lookup is back"; fi

t "the PasswordLogin curl doesn't use -f (an HTTP error must reach the message, not set -e)"
if grep -q 'LOGIN_RESP="$(curl -sS --max-time 10 -X POST "$API/api/Account/PasswordLogin"' run.sh; then ok; else bad "login curl changed"; fi

LOGIN_BLOCK="$(awk '/^  LOGIN_RESP="\$\(curl /,/report_login_failure "\$EMAIL"/' run.sh)"
t "the login block can be extracted from run.sh"
if [ -n "$LOGIN_BLOCK" ] && printf '%s' "$LOGIN_BLOCK" | grep -q 'report_login_failure'; then ok; else bad "block not found"; exit 1; fi

HELPERS="$(grep '^ADMIN_PW_MIN_LEN=' run.sh; awk '/^parse_login_resp\(\) \{/,/^}/' run.sh; awk '/^report_login_failure\(\) \{/,/^}/' run.sh)"

echo "parse_login_resp():"
plr() { # body expected label
  t "$3"
  local got; got="$(eval "$HELPERS"; printf '%s' "$1" | parse_login_resp)"
  if [ "$got" = "$2" ]; then ok; else bad "got '$got' (expected '$2')"; fi
}
plr '{"access_token":"abc.def","mustChangePassword":false}' "abc.def 0" "token response"
plr '{"mustChangePassword":true,"challengeCode":"x"}'       "- 1"       "mustChangePassword response"
plr '{"error":"invalid_grant"}'                              "- 0"       "error JSON"
plr '<html>502 Bad Gateway</html>'                           "- 0"       "non-JSON body"
plr ''                                                       "- 0"       "empty body"
plr '[1,2]'                                                  "- 0"       "JSON that isn't an object"

# Runs the real login block under set -euo pipefail with curl stubbed to print $1 and exit $2.
# Prints "JWT=<value>" (only if the block completed), then "rc=<exit status>", on stdout; stderr to $ERRF.
# A fresh `bash` process, not a ( subshell ): errexit is ignored inside a subshell whose caller sits in
# an && / || list or a function called that way, which would hide exactly the silent abort under test.
ERRF="$(mktemp)"; trap 'rm -f "$ERRF"' EXIT
login() { # body curl_rc
  HELPERS="$HELPERS" LOGIN_BLOCK="$LOGIN_BLOCK" CURL_BODY="$1" CURL_RC="$2" bash -c '
    set -euo pipefail
    eval "$HELPERS"
    curl() { printf "%s" "$CURL_BODY"; return "$CURL_RC"; }
    EMAIL="admin@example.com"; PASSWORD="LongEnough123"; API="http://localhost:60021"; UI_PORT=4200
    eval "$LOGIN_BLOCK"
    echo "JWT=$JWT"' 2>"$ERRF"
  echo "rc=$?"
}

echo "login block under set -euo pipefail:"
t "token response → continues with JWT set"
out="$(login '{"access_token":"abc.def"}' 0)"
if printf '%s' "$out" | grep -qx 'JWT=abc.def' && printf '%s' "$out" | grep -qx 'rc=0' && [ ! -s "$ERRF" ]; then ok; else bad "out=$out stderr=$(cat "$ERRF")"; fi

t "mustChangePassword → exit 1 with the password-change message (not silent)"
out="$(login '{"mustChangePassword":true,"challengeCode":"x"}' 0)"
if printf '%s' "$out" | grep -qx 'rc=1' && ! printf '%s' "$out" | grep -q '^JWT=' \
   && grep -q 'needs a password change' "$ERRF" && grep -q 'at least 12 characters' "$ERRF" \
   && grep -q 'http://localhost:4200' "$ERRF" && grep -q -- '--password' "$ERRF" && grep -q -- '--reset' "$ERRF"; then ok
else bad "out=$out stderr=$(cat "$ERRF")"; fi

t "401 error JSON → exit 1 with \"Login failed\""
out="$(login '{"error":"invalid_grant"}' 0)"
if printf '%s' "$out" | grep -qx 'rc=1' && grep -q 'Login failed for admin@example.com' "$ERRF"; then ok; else bad "out=$out stderr=$(cat "$ERRF")"; fi

t "non-JSON body → exit 1 with \"Login failed\""
out="$(login '<html>502</html>' 0)"
if printf '%s' "$out" | grep -qx 'rc=1' && grep -q 'Login failed' "$ERRF"; then ok; else bad "out=$out stderr=$(cat "$ERRF")"; fi

t "curl failure (timeout/refused, empty body) → exit 1 with \"Login failed\""
out="$(login '' 28)"
if printf '%s' "$out" | grep -qx 'rc=1' && grep -q 'Login failed' "$ERRF"; then ok; else bad "out=$out stderr=$(cat "$ERRF")"; fi

echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
