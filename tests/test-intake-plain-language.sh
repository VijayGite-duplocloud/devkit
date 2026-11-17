#!/usr/bin/env bash
# Checks the extension intake that /duplo-extension and the in-product Extension ticket both run:
# the questions put to the user are in plain words, the command takes its questions from the skill,
# and the skill's file references point at real paths.
#
# The plain-words rule is checked on two table columns inside SKILL.md's "Talking to the user"
# subsection: "Ask the user" (the question table) and "What the agent says" (the four patterns).
# Those cells are what the agent reads out; the rest of SKILL.md is the agent's own checklist and
# keeps its technical names.
#
# Static only: reads markdown, starts nothing.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
PASS=0; FAIL=0
t()   { printf '  %s … ' "$1"; }
ok()  { echo "ok"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

SKILL=.claude/skills/duplo-extension-dev/SKILL.md
CMD=.claude/commands/duplo-extension.md
DOCS=(docs/quickstart.md docs/getting-started/build-your-first-extension.md)
# Platform words a first-time user cannot be expected to know. Plurals included.
BANNED='\b(specs?|results?|resources?|scopes?|providers?|provisioning|modes?|crud|endpoints?|controllers?|fe|section ids?|origintypes?|remotes?)\b'

# The "Talking to the user" subsection: from its heading to the next ## or ### heading.
talking() { awk '/^### Talking to the user/{on=1; print; next} on && /^##{1,2}#? /{exit} on' "$SKILL"; }

# Prints the cells of every table column whose header is exactly "$1", one per line.
column_cells() {
  talking | awk -F'|' -v want="$1" '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    /^\|/ {
      if (!intable) { intable=1; col=0; for (i=2; i<NF; i++) if (trim($i)==want) col=i; next }
      if ($0 ~ /^\|[ \t:|-]+\|[ \t]*$/) next
      if (col) print trim($col)
      next
    }
    { intable=0; col=0 }'
}

t "SKILL.md has a 'Talking to the user' subsection inside Phase 1"
if awk '/^## Phase 1/{p=1} /^## Phase 2/{p=0} p && /^### Talking to the user/{f=1} END{exit !f}' "$SKILL"; then ok
else bad "no '### Talking to the user' between '## Phase 1' and '## Phase 2'"; fi

for col in "Ask the user" "What the agent says"; do
  t "the '$col' column exists and holds no platform words"
  cells=$(column_cells "$col")
  if [ -z "$cells" ]; then bad "no '$col' column in the subsection"
  elif hits=$(printf '%s\n' "$cells" | grep -inE "$BANNED"); then bad "platform words in: $hits"
  else ok; fi
done

t "the four patterns carry their plain names"
missing=""
for name in "Background job" "AI agent" "Instant" "Read-only"; do talking | grep -q "$name" || missing+=" '$name'"; done
[ -z "$missing" ] && ok || bad "missing:$missing"

t "the in-product pause is defined (Build it / Change something / Review what I'll build)"
if grep -q "Build it" "$SKILL" && grep -q "Change something" "$SKILL" && grep -q "Review what I'll build" "$SKILL"; then ok
else bad "pause wording missing from $SKILL"; fi

t "SKILL.md no longer asks for a menu 'section id'"
grep -qi "section id /" "$SKILL" && bad "the 'section id / top-level / none' question is still in $SKILL" || ok

t "SKILL.md copies the scaffold from a real path"
grep -q 'dirname "\$0"' "$SKILL" && bad "\$(dirname \"\$0\") resolves to the shell in Claude's Bash" || ok

t "SKILL.md does not call the public devkit repo private"
grep -q "PRIVATE" "$SKILL" && bad "'PRIVATE' still in $SKILL" || ok

t "SKILL.md's reference index labels the admin-resources guide by its file number"
grep -q "22-admin-resources" "$SKILL" && bad "'22-admin-resources' label still present" || ok

t "the command takes its questions from the skill"
if ! grep -q "Talking to the user" "$CMD"; then bad "no pointer to 'Talking to the user' in $CMD"
elif hits=$(grep -nE "ParentRefSpec|consumed by the FE|named action" "$CMD"); then bad "own question list still in $CMD: $hits"
else ok; fi

t "the command links reference guides by repo path"
hits=$(grep -nE '(^|[ (`])reference/[0-9]' "$CMD")
[ -z "$hits" ] && ok || bad "bare reference/ links: $hits"

t "the docs no longer promise options with 'Other'"
hits=$(grep -n 'with \*\*Other\*\*' "${DOCS[@]}")
[ -z "$hits" ] && ok || bad "$hits"

echo
echo "intake plain-language: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
