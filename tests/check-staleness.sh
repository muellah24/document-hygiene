#!/usr/bin/env bash
# Regression suite for bin/check-staleness (the PM-doc staleness evaluator:
# rules T1/T1b, T2, T3, T4). Feeds JSON fixtures on stdin exactly the way a
# tool recipe (skills/document-hygiene/references/*.md) would, and checks the
# JSON it prints on stdout. No state, no HOME isolation needed: the script
# reads stdin and writes stdout only. Prints PASS/FAIL per case; exits
# non-zero on any FAIL.

set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd -P)
CS="${CHECK_STALENESS_BIN:-$REPO_ROOT/bin/check-staleness}"

FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }

# run_cs <json>: runs check-staleness on the given JSON. Sets $out to stdout
# and $rc to the exit code every time, so every case below can assert both
# the exit code and the JSON shape, not just one field of it.
run_cs() {
  out=$(printf '%s' "$1" | "$CS")
  rc=$?
}
run_cs_quiet() {
  out=$(printf '%s' "$1" | "$CS" --quiet)
  rc=$?
}

jqget() {
  # jqget <json-output> <filter>
  printf '%s' "$1" | jq -r "$2" 2>/dev/null
}

# ok_success: true when the last run_cs call exited 0 and printed non-empty,
# well-formed JSON. Every success-path case below is gated on this, per FIX
# F5 ("every case must assert successful execution"), not only its own field.
ok_success() {
  [ "$rc" -eq 0 ] && [ -n "$out" ] && printf '%s' "$out" | jq -e . >/dev/null 2>&1
}

# ok_exit2 <expect-substring>: true when the last run_cs call exited 2 with a
# non-empty stderr-shaped message. Since run_cs only captures stdout, callers
# that need exit-2 cases capture stderr explicitly (see below) rather than
# using this helper directly for the message text; this helper is here for
# the common "just check rc==2" shape reused by several cases.
ok_exit2() { [ "$rc" -eq 2 ]; }

# --- syntax check -------------------------------------------------------------

if bash -n "$CS"; then
  pass "bash -n on bin/check-staleness"
else
  fail "bash -n on bin/check-staleness"
fi

# --- case 1: synthetic reconstruction of the 2026-09-24 Linear incident ------
# Fires on T1 (x2), T2, T4; must NOT fire T3 (doc is well under maxAgeDays old).

read -r -d '' CASE1 <<'EOF' || true
{
  "doc": {
    "text": "# Project status\n\n## Tickets\n- TECH-1317: planned (30 param descriptions to import)\n- TECH-1323: not started\n- TECH-1300: done\n\n## Decision\nWe will use claude-opus-5 for the extraction step.\n",
    "updatedAt": "2026-09-23T07:48:49Z"
  },
  "issues": [
    {"id": "TECH-1317", "state": "Done", "stateType": "completed", "createdAt": "2026-08-01T00:00:00Z", "updatedAt": "2026-09-23T14:55:00Z"},
    {"id": "TECH-1323", "state": "In Progress", "stateType": "started", "createdAt": "2026-08-01T00:00:00Z", "updatedAt": "2026-09-23T10:00:00Z"},
    {"id": "TECH-1300", "state": "Done", "stateType": "completed", "createdAt": "2026-07-01T00:00:00Z", "updatedAt": "2026-08-01T00:00:00Z"},
    {"id": "TECH-1330", "state": "Backlog", "stateType": "backlog", "createdAt": "2026-09-23T09:00:00Z", "updatedAt": "2026-09-23T09:00:00Z"},
    {"id": "TECH-1331", "state": "Backlog", "stateType": "backlog", "createdAt": "2026-09-23T09:05:00Z", "updatedAt": "2026-09-23T09:05:00Z"},
    {"id": "TECH-1332", "state": "Backlog", "stateType": "backlog", "createdAt": "2026-09-23T09:10:00Z", "updatedAt": "2026-09-23T09:10:00Z"},
    {"id": "TECH-1333", "state": "Backlog", "stateType": "backlog", "createdAt": "2026-09-23T09:15:00Z", "updatedAt": "2026-09-23T09:15:00Z"},
    {"id": "TECH-1334", "state": "Backlog", "stateType": "backlog", "createdAt": "2026-09-23T09:20:00Z", "updatedAt": "2026-09-23T09:20:00Z"}
  ],
  "options": {"now": "2026-09-24T05:00:00Z"}
}
EOF
run_cs "$CASE1"
fire=$(jqget "$out" '.fire')
rules=$(jqget "$out" '[.reasons[].rule] | unique | sort | join(",")')
t1_ids_classes=$(jqget "$out" '[.reasons[] | select(.rule=="T1") | .issue + ":" + (.detail | capture("\\((?<c>[a-z]+)\\)").c)] | sort | join(",")')
if ok_success && [ "$fire" = "true" ] && [ "$rules" = "T1,T2,T4" ] \
   && [ "$t1_ids_classes" = "TECH-1317:unstarted,TECH-1323:unstarted" ]; then
  pass "case1: 2026-09-24 reconstruction fires T1+T2+T4 (TECH-1317 and TECH-1323, both class unstarted), not T3"
else
  fail "case1: 2026-09-24 reconstruction fires T1+T2+T4 (TECH-1317 and TECH-1323, both class unstarted), not T3 (rc=$rc fire=$fire rules=$rules t1=$t1_ids_classes out=$out)"
fi

# --- case 2: a current doc -> no fire ----------------------------------------

read -r -d '' CASE2 <<'EOF' || true
{
  "doc": {"text": "# Status\n\n- TECH-1: done\n", "updatedAt": "2026-09-23T12:00:00Z"},
  "issues": [{"id": "TECH-1", "stateType": "completed", "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-09-23T11:00:00Z"}],
  "options": {"now": "2026-09-24T00:00:00Z"}
}
EOF
run_cs "$CASE2"
fire=$(jqget "$out" '.fire')
nreasons=$(jqget "$out" '.reasons | length')
if ok_success && [ "$fire" = "false" ] && [ "$nreasons" = "0" ]; then
  pass "case2: current doc does not fire"
else
  fail "case2: current doc does not fire (rc=$rc got: $out)"
fi

# --- case 3: T1 word-class mismatch, one per class ---------------------------

check_t1_class() {
  # check_t1_class <label> <line_word> <actual_stateType> <expected_class>
  label="$1"; word="$2"; state="$3"; expect_class="${4:-}"
  json=$(printf '{"doc":{"text":"- TICK-1: %s\\n","updatedAt":"2026-09-20T00:00:00Z"},"issues":[{"id":"TICK-1","stateType":"%s","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-09-21T00:00:00Z"}],"options":{"now":"2026-09-24T00:00:00Z"}}' "$word" "$state")
  run_cs "$json"
  rule=$(jqget "$out" '.reasons[0].rule // "none"')
  issue=$(jqget "$out" '.reasons[0].issue // "none"')
  detail=$(jqget "$out" '.reasons[0].detail // ""')
  fire=$(jqget "$out" '.fire')
  class_ok=1
  [ -n "$expect_class" ] && { printf '%s' "$detail" | grep -qF "($expect_class)" || class_ok=0; }
  if ok_success && [ "$fire" = "true" ] && [ "$rule" = "T1" ] && [ "$issue" = "TICK-1" ] && [ "$class_ok" = "1" ]; then
    pass "case3 ($label): '$word' vs stateType=$state fires T1 (issue=TICK-1, detail names the class)"
  else
    fail "case3 ($label): '$word' vs stateType=$state fires T1 (rc=$rc got: $out)"
  fi
}
# unstarted word, issue actually completed
check_t1_class "unstarted-word" "planned" "completed" "unstarted"
# started word, issue actually completed
check_t1_class "started-word" "in progress" "completed" "started"
# completed word, issue actually started
check_t1_class "completed-word" "done" "started" "completed"

# A word from every unstarted synonym should classify as unstarted (spot check
# a few, not just "planned"): backlog, not yet, upcoming, todo, to do,
# not started. "later" is deliberately NOT in this list any more (FIX F4
# dropped it, along with "live", "building", "wip", as generic standalone
# words too likely to appear in unrelated prose sharing a line with an ID).
for w in "backlog" "not yet" "upcoming" "todo" "to do" "not started"; do
  check_t1_class "unstarted synonym '$w'" "$w" "completed" "unstarted"
done

# case3b: "later" no longer classifies as anything (regression guard for the
# word actually being dropped, not just absent from the loop above).
json='{"doc":{"text":"- TICK-1: later\n","updatedAt":"2026-09-20T00:00:00Z"},"issues":[{"id":"TICK-1","stateType":"unstarted","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-09-19T00:00:00Z"}],"options":{"now":"2026-09-24T00:00:00Z"}}'
run_cs "$json"
fire=$(jqget "$out" '.fire')
nreasons=$(jqget "$out" '.reasons | length')
if ok_success && [ "$fire" = "false" ] && [ "$nreasons" = "0" ]; then
  pass "case3b: 'later' is no longer a recognized status word (dropped per FIX F4)"
else
  fail "case3b: 'later' is no longer a recognized status word (dropped per FIX F4) (rc=$rc got: $out)"
fi

# case3c: "not started" against an issue that really is unstarted -> no fire.
json='{"doc":{"text":"- TICK-1: not started\n","updatedAt":"2026-09-20T00:00:00Z"},"issues":[{"id":"TICK-1","stateType":"unstarted","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-09-19T00:00:00Z"}],"options":{"now":"2026-09-24T00:00:00Z"}}'
run_cs "$json"
fire=$(jqget "$out" '.fire')
nreasons=$(jqget "$out" '.reasons | length')
if ok_success && [ "$fire" = "false" ] && [ "$nreasons" = "0" ]; then
  pass "case3c: 'not started' vs a genuinely unstarted issue does not fire"
else
  fail "case3c: 'not started' vs a genuinely unstarted issue does not fire (rc=$rc got: $out)"
fi

# case3d: "not started" against an issue that is actually started -> T1 fires,
# classified unstarted (never ambiguously matching bare "started" too).
json='{"doc":{"text":"- TICK-1: not started\n","updatedAt":"2026-09-20T00:00:00Z"},"issues":[{"id":"TICK-1","stateType":"started","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-09-19T00:00:00Z"}],"options":{"now":"2026-09-24T00:00:00Z"}}'
run_cs "$json"
rule=$(jqget "$out" '.reasons[0].rule // "none"')
issue=$(jqget "$out" '.reasons[0].issue // "none"')
n=$(jqget "$out" '.reasons | length')
detail=$(jqget "$out" '.reasons[0].detail // ""')
fire=$(jqget "$out" '.fire')
if ok_success && [ "$fire" = "true" ] && [ "$rule" = "T1" ] && [ "$issue" = "TICK-1" ] && [ "$n" = "1" ] && printf '%s' "$detail" | grep -qF "(unstarted)"; then
  pass "case3d: 'not started' vs a started issue fires T1 once on TICK-1, classified unstarted (not ambiguous)"
else
  fail "case3d: 'not started' vs a started issue fires T1 once on TICK-1, classified unstarted (not ambiguous) (rc=$rc got: $out)"
fi

# case3e: "not yet started" is the same ambiguity risk as "not started" (the
# combined regex could otherwise match "not yet" for unstarted AND a bare
# "started" for started in the same clause): must resolve cleanly to
# unstarted only, same as case3d.
json='{"doc":{"text":"- TICK-1: not yet started\n","updatedAt":"2026-09-20T00:00:00Z"},"issues":[{"id":"TICK-1","stateType":"completed","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-09-19T00:00:00Z"}],"options":{"now":"2026-09-24T00:00:00Z"}}'
run_cs "$json"
rule=$(jqget "$out" '.reasons[0].rule // "none"')
issue=$(jqget "$out" '.reasons[0].issue // "none"')
n=$(jqget "$out" '.reasons | length')
detail=$(jqget "$out" '.reasons[0].detail // ""')
fire=$(jqget "$out" '.fire')
if ok_success && [ "$fire" = "true" ] && [ "$rule" = "T1" ] && [ "$issue" = "TICK-1" ] && [ "$n" = "1" ] && printf '%s' "$detail" | grep -qF "(unstarted)"; then
  pass "case3e: 'not yet started' vs a completed issue fires T1 once on TICK-1, classified unstarted (not ambiguous)"
else
  fail "case3e: 'not yet started' vs a completed issue fires T1 once on TICK-1, classified unstarted (not ambiguous) (rc=$rc got: $out)"
fi

# --- case 4: T1b, no status word anywhere for the issue ----------------------

read -r -d '' CASE4 <<'EOF' || true
{
  "doc": {"text": "See TICK-9 for details.\n", "updatedAt": "2026-09-23T00:00:00Z"},
  "issues": [{"id": "TICK-9", "stateType": "started", "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-09-23T20:00:00Z"}],
  "options": {"now": "2026-09-24T00:00:00Z"}
}
EOF
run_cs "$CASE4"
rule=$(jqget "$out" '.reasons[0].rule // "none"')
issue=$(jqget "$out" '.reasons[0].issue // "none"')
fire=$(jqget "$out" '.fire')
if ok_success && [ "$fire" = "true" ] && [ "$rule" = "T1b" ] && [ "$issue" = "TICK-9" ]; then
  pass "case4: no status word + issue updated after doc fires T1b on TICK-9"
else
  fail "case4: no status word + issue updated after doc fires T1b on TICK-9 (rc=$rc got: $out)"
fi

# case 4b: T1b is suppressed when ANOTHER line about the same issue does carry
# a (matching) status word: one reason per issue, not per line.
read -r -d '' CASE4B <<'EOF' || true
{
  "doc": {"text": "See TICK-9 for details.\nTICK-9 is in progress.\n", "updatedAt": "2026-09-23T00:00:00Z"},
  "issues": [{"id": "TICK-9", "stateType": "started", "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-09-23T20:00:00Z"}],
  "options": {"now": "2026-09-24T00:00:00Z"}
}
EOF
run_cs "$CASE4B"
fire=$(jqget "$out" '.fire')
nreasons=$(jqget "$out" '.reasons | length')
if ok_success && [ "$fire" = "false" ] && [ "$nreasons" = "0" ]; then
  pass "case4b: T1b suppressed when another line about the same issue has a matching status word"
else
  fail "case4b: T1b suppressed when another line about the same issue has a matching status word (rc=$rc got: $out)"
fi

# case 4c: T1b never fires twice for the same issue even when it is referenced
# on two lines, neither of which has a status word.
read -r -d '' CASE4C <<'EOF' || true
{
  "doc": {"text": "TICK-9 header\nTICK-9 again in the body\n", "updatedAt": "2026-09-23T00:00:00Z"},
  "issues": [{"id": "TICK-9", "stateType": "started", "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-09-23T20:00:00Z"}],
  "options": {"now": "2026-09-24T00:00:00Z"}
}
EOF
run_cs "$CASE4C"
n=$(jqget "$out" '[.reasons[] | select(.rule=="T1b")] | length')
fire=$(jqget "$out" '.fire')
if ok_success && [ "$fire" = "true" ] && [ "$n" = "1" ]; then
  pass "case4c: T1b fires exactly once per issue, not once per referencing line"
else
  fail "case4c: T1b fires exactly once per issue, not once per referencing line (rc=$rc count=$n, out=$out)"
fi

# case4d: T1b's "no status word" check stays LINE-scoped even though F4 made
# T1's attribution clause-scoped. "TICK-9, in progress" splits into two
# clauses at the comma (TICK-9's own clause has no status word), but the
# line as a whole clearly has one, so T1b must NOT fire here. T1 also
# correctly does not fire, since "in progress" is not attributed to TICK-9
# across the clause boundary, but that is a T1 non-finding, not evidence of
# "no status word at all on this line" for T1b's purposes.
read -r -d '' CASE4D <<'EOF' || true
{
  "doc": {"text": "TICK-9, in progress\n", "updatedAt": "2026-09-23T00:00:00Z"},
  "issues": [{"id": "TICK-9", "stateType": "started", "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-09-23T20:00:00Z"}],
  "options": {"now": "2026-09-24T00:00:00Z"}
}
EOF
run_cs "$CASE4D"
fire=$(jqget "$out" '.fire')
nreasons=$(jqget "$out" '.reasons | length')
if ok_success && [ "$fire" = "false" ] && [ "$nreasons" = "0" ]; then
  pass "case4d: T1b stays line-scoped (a status word elsewhere on the line suppresses it, even across a clause boundary)"
else
  fail "case4d: T1b stays line-scoped (a status word elsewhere on the line suppresses it, even across a clause boundary) (rc=$rc got: $out)"
fi

# --- case 5: T2 volume threshold (default 5) ---------------------------------

build_issues() {
  n="$1"; state="${2:-started}"; upd="${3:-2026-09-21T00:00:00Z}"
  out="["
  for i in $(seq 1 "$n"); do
    [ "$i" -gt 1 ] && out="$out,"
    out="$out{\"id\":\"VOL-$i\",\"stateType\":\"$state\",\"createdAt\":\"2026-01-01T00:00:00Z\",\"updatedAt\":\"$upd\"}"
  done
  out="$out]"
  printf '%s' "$out"
}
issues5=$(build_issues 5)
json=$(printf '{"doc":{"text":"nothing here\\n","updatedAt":"2026-09-20T00:00:00Z"},"issues":%s,"options":{"now":"2026-09-24T00:00:00Z"}}' "$issues5")
run_cs "$json"
has_t2=$(jqget "$out" '[.reasons[] | select(.rule=="T2")] | length')
fire=$(jqget "$out" '.fire')
if ok_success && [ "$fire" = "true" ] && [ "$has_t2" = "1" ]; then
  pass "case5: 5 issues updated since doc meets the default volume threshold"
else
  fail "case5: 5 issues updated since doc meets the default volume threshold (rc=$rc got: $out)"
fi

issues4=$(build_issues 4)
json=$(printf '{"doc":{"text":"nothing here\\n","updatedAt":"2026-09-20T00:00:00Z"},"issues":%s,"options":{"now":"2026-09-24T00:00:00Z"}}' "$issues4")
run_cs "$json"
fire=$(jqget "$out" '.fire')
nreasons=$(jqget "$out" '.reasons | length')
if ok_success && [ "$fire" = "false" ] && [ "$nreasons" = "0" ]; then
  pass "case5b: 4 issues (below threshold) does not fire"
else
  fail "case5b: 4 issues (below threshold) does not fire (rc=$rc got: $out)"
fi

# --- case 6: T3 age, active vs inactive project ------------------------------

read -r -d '' CASE6A <<'EOF' || true
{
  "doc": {"text": "nothing here\n", "updatedAt": "2026-09-01T00:00:00Z"},
  "issues": [{"id": "AGE-1", "stateType": "started", "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-09-22T00:00:00Z"}],
  "options": {"now": "2026-09-24T00:00:00Z"}
}
EOF
run_cs "$CASE6A"
has_t3=$(jqget "$out" '[.reasons[] | select(.rule=="T3")] | length')
fire=$(jqget "$out" '.fire')
if ok_success && [ "$fire" = "true" ] && [ "$has_t3" = "1" ]; then
  pass "case6a: old doc + active project fires T3"
else
  fail "case6a: old doc + active project fires T3 (rc=$rc got: $out)"
fi

read -r -d '' CASE6B <<'EOF' || true
{
  "doc": {"text": "nothing here\n", "updatedAt": "2026-09-01T00:00:00Z"},
  "issues": [{"id": "AGE-1", "stateType": "started", "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-02T00:00:00Z"}],
  "options": {"now": "2026-09-24T00:00:00Z"}
}
EOF
run_cs "$CASE6B"
fire=$(jqget "$out" '.fire')
nreasons=$(jqget "$out" '.reasons | length')
if ok_success && [ "$fire" = "false" ] && [ "$nreasons" = "0" ]; then
  pass "case6b: old doc + inactive project does not fire"
else
  fail "case6b: old doc + inactive project does not fire (rc=$rc got: $out)"
fi

# --- case 7: canceled issues ignored for T2/T4 -------------------------------

read -r -d '' CASE7 <<'EOF' || true
{
  "doc": {"text": "nothing here\n", "updatedAt": "2026-09-20T00:00:00Z"},
  "issues": [
    {"id": "CAN-1", "stateType": "canceled", "createdAt": "2026-09-21T00:00:00Z", "updatedAt": "2026-09-21T00:00:00Z"},
    {"id": "CAN-2", "stateType": "canceled", "createdAt": "2026-09-21T00:00:00Z", "updatedAt": "2026-09-21T00:00:00Z"},
    {"id": "CAN-3", "stateType": "canceled", "createdAt": "2026-09-21T00:00:00Z", "updatedAt": "2026-09-21T00:00:00Z"},
    {"id": "CAN-4", "stateType": "canceled", "createdAt": "2026-09-21T00:00:00Z", "updatedAt": "2026-09-21T00:00:00Z"},
    {"id": "CAN-5", "stateType": "canceled", "createdAt": "2026-09-21T00:00:00Z", "updatedAt": "2026-09-21T00:00:00Z"}
  ],
  "options": {"now": "2026-09-24T00:00:00Z"}
}
EOF
run_cs "$CASE7"
fire=$(jqget "$out" '.fire')
counts=$(jqget "$out" '.counts.changedSinceDoc, .counts.newUnreferenced' | tr '\n' ' ')
nreasons=$(jqget "$out" '.reasons | length')
if ok_success && [ "$fire" = "false" ] && [ "$counts" = "0 0 " ] && [ "$nreasons" = "0" ]; then
  pass "case7: canceled issues are excluded from T2/T4 counts and don't fire"
else
  fail "case7: canceled issues are excluded from T2/T4 counts and don't fire (rc=$rc fire=$fire counts='$counts' out=$out)"
fi

# --- case 8: an ID embedded inside a URL is still matched --------------------

read -r -d '' CASE8 <<'EOF' || true
{
  "doc": {"text": "See https://example.com/issue/TECH-1317/ for planned work.\n", "updatedAt": "2026-09-20T00:00:00Z"},
  "issues": [{"id": "TECH-1317", "stateType": "completed", "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-09-21T00:00:00Z"}],
  "options": {"now": "2026-09-24T00:00:00Z"}
}
EOF
run_cs "$CASE8"
rule=$(jqget "$out" '.reasons[0].rule // "none"')
issue=$(jqget "$out" '.reasons[0].issue // "none"')
detail=$(jqget "$out" '.reasons[0].detail // ""')
fire=$(jqget "$out" '.fire')
if ok_success && [ "$fire" = "true" ] && [ "$rule" = "T1" ] && [ "$issue" = "TECH-1317" ] && printf '%s' "$detail" | grep -qF "(unstarted)"; then
  pass "case8: an ID embedded in a URL is matched and classified (TECH-1317, unstarted)"
else
  fail "case8: an ID embedded in a URL is matched and classified (TECH-1317, unstarted) (rc=$rc got: $out)"
fi

# T4 should also see an ID inside a URL as "referenced" (i.e. NOT unreferenced).
read -r -d '' CASE8B <<'EOF' || true
{
  "doc": {"text": "Tracking at https://example.com/issue/TECH-9999/\n", "updatedAt": "2026-09-20T00:00:00Z"},
  "issues": [{"id": "TECH-9999", "stateType": "unstarted", "createdAt": "2026-09-21T00:00:00Z", "updatedAt": "2026-09-21T00:00:00Z"}],
  "options": {"now": "2026-09-24T00:00:00Z"}
}
EOF
run_cs "$CASE8B"
newunref=$(jqget "$out" '.counts.newUnreferenced')
fire=$(jqget "$out" '.fire')
nreasons=$(jqget "$out" '.reasons | length')
if ok_success && [ "$newunref" = "0" ] && [ "$fire" = "false" ] && [ "$nreasons" = "0" ]; then
  pass "case8b: an ID inside a URL counts as referenced for T4"
else
  fail "case8b: an ID inside a URL counts as referenced for T4 (rc=$rc got: $out)"
fi

# case8c: same as 8b but the ID is lowercased inside the URL (trackers and
# URLs lowercase identifiers routinely; FIX F3 requires case-insensitive
# matching for T4 too, not only for T1).
read -r -d '' CASE8C <<'EOF' || true
{
  "doc": {"text": "Tracking at https://example.com/issue/tech-9999/\n", "updatedAt": "2026-09-20T00:00:00Z"},
  "issues": [{"id": "TECH-9999", "stateType": "unstarted", "createdAt": "2026-09-21T00:00:00Z", "updatedAt": "2026-09-21T00:00:00Z"}],
  "options": {"now": "2026-09-24T00:00:00Z"}
}
EOF
run_cs "$CASE8C"
fire=$(jqget "$out" '.fire')
newunref=$(jqget "$out" '.counts.newUnreferenced')
nreasons=$(jqget "$out" '.reasons | length')
if ok_success && [ "$newunref" = "0" ] && [ "$fire" = "false" ] && [ "$nreasons" = "0" ]; then
  pass "case8c: a lowercased ID inside a URL still counts as referenced for T4 (no fire)"
else
  fail "case8c: a lowercased ID inside a URL still counts as referenced for T4 (no fire) (rc=$rc got: $out)"
fi

# case8d: TECH-1X must NOT match a known TECH-1 (token boundary), so if only
# TECH-1 is a known issue, a doc that only says "TECH-1X planned" has NOT
# referenced TECH-1 and carries no status evidence for it either.
read -r -d '' CASE8D <<'EOF' || true
{
  "doc": {"text": "TECH-1X planned\n", "updatedAt": "2026-09-20T00:00:00Z"},
  "issues": [{"id": "TECH-1", "stateType": "completed", "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-09-19T00:00:00Z"}],
  "options": {"now": "2026-09-24T00:00:00Z"}
}
EOF
run_cs "$CASE8D"
fire=$(jqget "$out" '.fire')
nreasons=$(jqget "$out" '.reasons | length')
if ok_success && [ "$fire" = "false" ] && [ "$nreasons" = "0" ]; then
  pass "case8d: 'TECH-1X planned' with only TECH-1 known does not match TECH-1 (token boundary), no fire"
else
  fail "case8d: 'TECH-1X planned' with only TECH-1 known does not match TECH-1 (token boundary), no fire (rc=$rc got: $out)"
fi

# --- case 9: multi-ID line does not cross-contaminate classification --------

read -r -d '' CASE9 <<'EOF' || true
{
  "doc": {"text": "TECH-1 done, TECH-2 in progress\n", "updatedAt": "2026-09-20T00:00:00Z"},
  "issues": [
    {"id": "TECH-1", "stateType": "completed", "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-09-19T00:00:00Z"},
    {"id": "TECH-2", "stateType": "started", "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-09-19T00:00:00Z"}
  ],
  "options": {"now": "2026-09-24T00:00:00Z"}
}
EOF
run_cs "$CASE9"
fire=$(jqget "$out" '.fire')
nreasons=$(jqget "$out" '.reasons | length')
if ok_success && [ "$fire" = "false" ] && [ "$nreasons" = "0" ]; then
  pass "case9: a two-ID line classifies each ID against its own clause (no cross-contamination)"
else
  fail "case9: a two-ID line classifies each ID against its own clause (no cross-contamination) (rc=$rc got: $out)"
fi

# case9b: the mismatching half of a two-ID line still fires T1, proving the
# clause split isn't just suppressing everything on a multi-ID line.
read -r -d '' CASE9B <<'EOF' || true
{
  "doc": {"text": "TECH-1 done, TECH-2 in progress\n", "updatedAt": "2026-09-20T00:00:00Z"},
  "issues": [
    {"id": "TECH-1", "stateType": "started", "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-09-19T00:00:00Z"},
    {"id": "TECH-2", "stateType": "started", "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-09-19T00:00:00Z"}
  ],
  "options": {"now": "2026-09-24T00:00:00Z"}
}
EOF
run_cs "$CASE9B"
t1issue=$(jqget "$out" '.reasons[0].issue // "none"')
n=$(jqget "$out" '.reasons | length')
detail=$(jqget "$out" '.reasons[0].detail // ""')
fire=$(jqget "$out" '.fire')
if ok_success && [ "$fire" = "true" ] && [ "$n" = "1" ] && [ "$t1issue" = "TECH-1" ] && printf '%s' "$detail" | grep -qF "(completed)"; then
  pass "case9b: only the actually-mismatched ID on a multi-ID line fires T1, class named in detail"
else
  fail "case9b: only the actually-mismatched ID on a multi-ID line fires T1, class named in detail (rc=$rc got: $out)"
fi

# --- case 10: the `now` override is honored ----------------------------------

read -r -d '' CASE10 <<'EOF' || true
{
  "doc": {"text": "nothing here\n", "updatedAt": "2026-09-01T00:00:00Z"},
  "issues": [{"id": "NOW-1", "stateType": "started", "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-09-01T01:00:00Z"}],
  "options": {"now": "2026-09-02T00:00:00Z"}
}
EOF
run_cs "$CASE10"
docage=$(jqget "$out" '.counts.docAgeDays')
fire=$(jqget "$out" '.fire')
nreasons=$(jqget "$out" '.reasons | length')
if ok_success && [ "$docage" = "1" ] && [ "$fire" = "false" ] && [ "$nreasons" = "0" ]; then
  pass "case10: options.now overrides the wall-clock date used for docAgeDays"
else
  fail "case10: options.now overrides the wall-clock date used for docAgeDays (rc=$rc got: $out)"
fi

# case10b: with no `now` override, docAgeDays is computed against the real
# wall clock (loosely checked: a doc from over a year ago is definitely old).
read -r -d '' CASE10B <<'EOF' || true
{
  "doc": {"text": "nothing here\n", "updatedAt": "2020-01-01T00:00:00Z"},
  "issues": []
}
EOF
run_cs "$CASE10B"
docage=$(jqget "$out" '.counts.docAgeDays')
fire=$(jqget "$out" '.fire')
nreasons=$(jqget "$out" '.reasons | length')
if ok_success && [ "${docage:-0}" -gt 300 ] 2>/dev/null && [ "$fire" = "false" ] && [ "$nreasons" = "0" ]; then
  pass "case10b: with no options.now, docAgeDays is computed against the real wall clock"
else
  fail "case10b: with no options.now, docAgeDays is computed against the real wall clock (rc=$rc got: $out)"
fi

# --- case 11: malformed input exits 2 with a stderr message ------------------

err=$(printf 'not json at all' | "$CS" 2>&1 1>/dev/null)
rc=$?
if [ "$rc" -eq 2 ] && [ -n "$err" ]; then
  pass "case11: malformed JSON exits 2 with a stderr message"
else
  fail "case11: malformed JSON exits 2 with a stderr message (rc=$rc err='$err')"
fi

# case11b: valid JSON but missing required fields also exits 2.
err=$(printf '{"foo":"bar"}' | "$CS" 2>&1 1>/dev/null)
rc=$?
if [ "$rc" -eq 2 ] && [ -n "$err" ]; then
  pass "case11b: valid JSON missing required fields exits 2 with a stderr message"
else
  fail "case11b: valid JSON missing required fields exits 2 with a stderr message (rc=$rc err='$err')"
fi

# case11c: a value jq cannot parse as a date (not merely malformed JSON) also
# exits 2 with a message, rather than silently printing nothing at exit 0.
err=$(printf '{"doc":{"text":"x","updatedAt":"not-a-date"},"issues":[]}' | "$CS" 2>&1 1>/dev/null)
rc=$?
if [ "$rc" -eq 2 ] && [ -n "$err" ]; then
  pass "case11c: an unparsable timestamp exits 2 with a message instead of failing silently"
else
  fail "case11c: an unparsable timestamp exits 2 with a message instead of failing silently (rc=$rc err='$err')"
fi

# case11d: `issues` missing entirely exits 2 (FIX F1: no longer silently
# defaulted to [] via `// []`, which used to yield a clean-looking fire:false
# for what is actually an adapter failure).
err=$(printf '{"doc":{"text":"x","updatedAt":"2026-09-20T00:00:00Z"}}' | "$CS" 2>&1 1>/dev/null)
rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$err" | grep -qi 'issues'; then
  pass "case11d: missing issues exits 2 with a message naming issues"
else
  fail "case11d: missing issues exits 2 with a message naming issues (rc=$rc err='$err')"
fi

# case11e: `issues: null` and `issues: false` both exit 2 too (not only a
# missing key).
for badval in 'null' 'false'; do
  err=$(printf '{"doc":{"text":"x","updatedAt":"2026-09-20T00:00:00Z"},"issues":%s}' "$badval" | "$CS" 2>&1 1>/dev/null)
  rc=$?
  if [ "$rc" -eq 2 ] && printf '%s' "$err" | grep -qi 'issues'; then
    pass "case11e (issues: $badval): exits 2 with a message naming issues"
  else
    fail "case11e (issues: $badval): exits 2 with a message naming issues (rc=$rc err='$err')"
  fi
done

# case11f: an empty `issues` array is explicitly VALID (a successfully
# fetched empty result is not the same as a missing/failed fetch).
run_cs '{"doc":{"text":"x","updatedAt":"2026-09-20T00:00:00Z"},"issues":[]}'
fire=$(jqget "$out" '.fire')
nreasons=$(jqget "$out" '.reasons | length')
if ok_success && [ "$fire" = "false" ] && [ "$nreasons" = "0" ]; then
  pass "case11f: an empty issues array is valid and evaluates cleanly"
else
  fail "case11f: an empty issues array is valid and evaluates cleanly (rc=$rc got: $out)"
fi

# case11g: options.volumeThreshold as a STRING ("5") is rejected, not
# silently accepted as if it disabled T2.
err=$(printf '{"doc":{"text":"x","updatedAt":"2026-09-20T00:00:00Z"},"issues":[],"options":{"volumeThreshold":"5"}}' | "$CS" 2>&1 1>/dev/null)
rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$err" | grep -qi 'volumeThreshold'; then
  pass "case11g: options.volumeThreshold as a string exits 2 with a message naming it"
else
  fail "case11g: options.volumeThreshold as a string exits 2 with a message naming it (rc=$rc err='$err')"
fi

# case11h: a malformed date on a CANCELED issue is still caught (validation
# happens up front, before rule filtering, so canceled issues are not
# exempt just because T2/T4 ignore them).
err=$(printf '{"doc":{"text":"x","updatedAt":"2026-09-20T00:00:00Z"},"issues":[{"id":"TICK-1","stateType":"canceled","createdAt":"2026-02-30T00:00:00Z","updatedAt":"2026-09-20T00:00:00Z"}]}' | "$CS" 2>&1 1>/dev/null)
rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$err" | grep -qi 'issues\[0\]'; then
  pass "case11h: a malformed date on a canceled issue still exits 2"
else
  fail "case11h: a malformed date on a canceled issue still exits 2 (rc=$rc err='$err')"
fi

# case11i: an impossible calendar date (Feb 30) exits 2.
err=$(printf '{"doc":{"text":"x","updatedAt":"2026-02-30T00:00:00Z"},"issues":[]}' | "$CS" 2>&1 1>/dev/null)
rc=$?
if [ "$rc" -eq 2 ] && [ -n "$err" ]; then
  pass "case11i: an impossible calendar date (Feb 30) exits 2"
else
  fail "case11i: an impossible calendar date (Feb 30) exits 2 (rc=$rc err='$err')"
fi

# case11j: an out-of-range UTC offset (+99:99) exits 2.
err=$(printf '{"doc":{"text":"x","updatedAt":"2026-09-20T00:00:00+99:99"},"issues":[]}' | "$CS" 2>&1 1>/dev/null)
rc=$?
if [ "$rc" -eq 2 ] && [ -n "$err" ]; then
  pass "case11j: an out-of-range UTC offset (+99:99) exits 2"
else
  fail "case11j: an out-of-range UTC offset (+99:99) exits 2 (rc=$rc err='$err')"
fi

# case11k: a date-only doc.updatedAt (no time part) is ACCEPTED (midnight
# UTC) and agrees with the other instant forms. Folded into case13 below,
# which gives it the same before/after positive control the other forms get
# instead of only checking rc.

# --- case 12: --quiet prints only fire/no fire -------------------------------

run_cs_quiet "$CASE1"
if [ "$rc" -eq 0 ] && [ "$out" = "fire" ]; then
  pass "case12: --quiet prints 'fire' for a firing case"
else
  fail "case12: --quiet prints 'fire' for a firing case (rc=$rc got: '$out')"
fi

run_cs_quiet "$CASE2"
if [ "$rc" -eq 0 ] && [ "$out" = "no fire" ]; then
  pass "case12b: --quiet prints 'no fire' for a clean case"
else
  fail "case12b: --quiet prints 'no fire' for a clean case (rc=$rc got: '$out')"
fi

# --- case 13: date-format equivalence (Z, +00:00, +0000, no offset) ---------
# These four forms all name the SAME instant (unlike ".000Z" vs ".999Z",
# which straddle a day boundary and are NOT equivalent under floor: that
# was the bug in the old version of this case). Each form is checked with a
# positive control: one issue 1 second after the instant (must count as
# changed) and one issue 1 second before it (must not), so the equivalence
# check can't pass merely because changedSinceDoc is trivially always 0 or
# always both.

check_instant_form() {
  # check_instant_form <label> <doc_updatedAt>
  label="$1"; ts="$2"
  before_after_issues='[{"id":"EDGE-1","stateType":"started","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-08-31T23:59:59Z"},{"id":"EDGE-2","stateType":"started","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-09-01T00:00:01Z"}]'
  json=$(printf '{"doc":{"text":"nothing here\\n","updatedAt":"%s"},"issues":%s,"options":{"now":"2026-09-24T00:00:00Z"}}' "$ts" "$before_after_issues")
  run_cs "$json"
  changed=$(jqget "$out" '.counts.changedSinceDoc')
  docage=$(jqget "$out" '.counts.docAgeDays')
  fire=$(jqget "$out" '.fire')
  nreasons=$(jqget "$out" '.reasons | length')
  if ok_success && [ "$changed" = "1" ] && [ "$fire" = "false" ] && [ "$nreasons" = "0" ]; then
    printf '%s %s\n' "$docage" "$changed"
  else
    printf 'FAILED rc=%s out=%s\n' "$rc" "$out"
  fi
}
r1=$(check_instant_form "Z" "2026-09-01T00:00:00Z")
r2=$(check_instant_form "+00:00" "2026-09-01T00:00:00+00:00")
r3=$(check_instant_form "+0000" "2026-09-01T00:00:00+0000")
r4=$(check_instant_form "no-offset" "2026-09-01T00:00:00")
r5=$(check_instant_form "date-only" "2026-09-01")
d1=$(printf '%s' "$r1" | cut -d' ' -f1)
d2=$(printf '%s' "$r2" | cut -d' ' -f1)
d3=$(printf '%s' "$r3" | cut -d' ' -f1)
d4=$(printf '%s' "$r4" | cut -d' ' -f1)
d5=$(printf '%s' "$r5" | cut -d' ' -f1)
any_failed=0
printf '%s\n%s\n%s\n%s\n%s\n' "$r1" "$r2" "$r3" "$r4" "$r5" | grep -q FAILED && any_failed=1
if [ "$any_failed" -eq 0 ] && [ "$d1" = "$d2" ] && [ "$d1" = "$d3" ] && [ "$d1" = "$d4" ] && [ "$d1" = "$d5" ]; then
  pass "case13: Z, +00:00, +0000, no-offset, and date-only forms of the same instant agree (docAgeDays=$d1, each with a passing before/after positive control)"
else
  fail "case13: Z, +00:00, +0000, no-offset, and date-only forms of the same instant agree (r1=[$r1] r2=[$r2] r3=[$r3] r4=[$r4] r5=[$r5])"
fi

# case13b: fractional-second ordering. A doc at ...00.100Z and an issue
# updated at ...00.900Z are 0.8s apart; the issue must count as changed
# (fractional seconds preserved in the epoch, not truncated) and, with no
# status word anywhere, T1b must fire.
read -r -d '' CASE13B <<'EOF' || true
{
  "doc": {"text": "See FRAC-1 for details.\n", "updatedAt": "2026-09-01T00:00:00.100Z"},
  "issues": [{"id": "FRAC-1", "stateType": "started", "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-09-01T00:00:00.900Z"}],
  "options": {"now": "2026-09-24T00:00:00Z"}
}
EOF
run_cs "$CASE13B"
changed=$(jqget "$out" '.counts.changedSinceDoc')
t1b=$(jqget "$out" '[.reasons[] | select(.rule=="T1b")] | length')
fire=$(jqget "$out" '.fire')
if ok_success && [ "$fire" = "true" ] && [ "$changed" = "1" ] && [ "$t1b" = "1" ]; then
  pass "case13b: fractional seconds are preserved, not truncated (0.8s apart still counts as changed, fires T1b)"
else
  fail "case13b: fractional seconds are preserved, not truncated (0.8s apart still counts as changed, fires T1b) (rc=$rc got: $out)"
fi

# Re-run the base equivalence under a DST-observing timezone, with a NO-OFFSET
# timestamp specifically (a "Z" timestamp is timezone-independent by
# construction and would test nothing about TZ-sensitivity): the comparisons
# must all happen in jq against ISO instants, never against the shell's local
# time, so TZ must not change the answer.
tz_json='{"doc":{"text":"x","updatedAt":"2026-09-01T00:00:00"},"issues":[],"options":{"now":"2026-09-24T00:00:00Z"}}'
out_budapest=$(printf '%s' "$tz_json" | TZ=Europe/Budapest "$CS")
out_default=$(printf '%s' "$tz_json" | "$CS")
e_budapest=$(jqget "$out_budapest" '.counts.docAgeDays')
e_default=$(jqget "$out_default" '.counts.docAgeDays')
fire_budapest=$(jqget "$out_budapest" '.fire')
fire_default=$(jqget "$out_default" '.fire')
nreasons_budapest=$(jqget "$out_budapest" '.reasons | length')
nreasons_default=$(jqget "$out_default" '.reasons | length')
if [ -n "$e_budapest" ] && [ "$e_budapest" = "$e_default" ] \
   && [ "$fire_budapest" = "false" ] && [ "$fire_default" = "false" ] \
   && [ "$nreasons_budapest" = "0" ] && [ "$nreasons_default" = "0" ]; then
  pass "case13c: TZ=Europe/Budapest (DST) does not change docAgeDays for a no-offset timestamp vs. the default timezone"
else
  fail "case13c: TZ=Europe/Budapest (DST) does not change docAgeDays for a no-offset timestamp vs. the default timezone (budapest=$e_budapest default=$e_default)"
fi

# --- case 14: a positive control straddling doc.updatedAt exactly -----------
# One issue 30 minutes before doc.updatedAt (must NOT count as changed-since-
# doc), one 30 minutes after (must count). Proves the ">" boundary isn't
# silently inverted or off by a wide margin.

read -r -d '' CASE14 <<'EOF' || true
{
  "doc": {"text": "nothing here\n", "updatedAt": "2026-09-20T12:00:00Z"},
  "issues": [
    {"id": "EDGE-1", "stateType": "started", "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-09-20T11:30:00Z"},
    {"id": "EDGE-2", "stateType": "started", "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-09-20T12:30:00Z"}
  ],
  "options": {"now": "2026-09-24T00:00:00Z"}
}
EOF
run_cs "$CASE14"
changed=$(jqget "$out" '.counts.changedSinceDoc')
fire=$(jqget "$out" '.fire')
nreasons=$(jqget "$out" '.reasons | length')
if ok_success && [ "$changed" = "1" ] && [ "$fire" = "false" ] && [ "$nreasons" = "0" ]; then
  pass "case14: an issue 30 minutes before doc.updatedAt is excluded, one 30 minutes after is included"
else
  fail "case14: an issue 30 minutes before doc.updatedAt is excluded, one 30 minutes after is included (rc=$rc got: $out)"
fi

# --- case 15: jq missing from PATH exits 2 with a message -------------------
# Built the same way tests/run.sh proves the hooks' own jq-missing branch: a
# PATH that genuinely cannot resolve jq, not merely a PATH override that
# hides a working jq.

build_restricted_path_no_jq() {
  d=$(mktemp -d)
  for b in cat mktemp rm bash grep; do
    p=$(command -v "$b" 2>/dev/null)
    [ -n "$p" ] && ln -sf "$p" "$d/$b"
  done
  printf '%s\n' "$d"
}
NO_JQ_PATH=$(build_restricted_path_no_jq)
err=$(printf '{"doc":{"text":"x","updatedAt":"2026-09-20T00:00:00Z"},"issues":[]}' \
  | PATH="$NO_JQ_PATH" "$CS" 2>&1 1>/dev/null)
rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$err" | grep -qi 'jq'; then
  pass "case15: jq missing from PATH exits 2 with a message naming jq"
else
  fail "case15: jq missing from PATH exits 2 with a message naming jq (rc=$rc err='$err')"
fi
rm -rf "$NO_JQ_PATH"

# --- case 16: T4 issue with a canceled-but-still-unreferenced sibling -------
# Restates case7 with a mix of canceled and non-canceled new issues, to prove
# the exclusion is per-issue, not "any canceled issue anywhere suppresses T4".

read -r -d '' CASE16 <<'EOF' || true
{
  "doc": {"text": "nothing here\n", "updatedAt": "2026-09-20T00:00:00Z"},
  "issues": [
    {"id": "MIX-1", "stateType": "canceled", "createdAt": "2026-09-21T00:00:00Z", "updatedAt": "2026-09-21T00:00:00Z"},
    {"id": "MIX-2", "stateType": "unstarted", "createdAt": "2026-09-21T00:00:00Z", "updatedAt": "2026-09-21T00:00:00Z"}
  ],
  "options": {"now": "2026-09-24T00:00:00Z"}
}
EOF
run_cs "$CASE16"
t4issues=$(jqget "$out" '[.reasons[] | select(.rule=="T4") | .issue] | join(",")')
fire=$(jqget "$out" '.fire')
if ok_success && [ "$fire" = "true" ] && [ "$t4issues" = "MIX-2" ]; then
  pass "case16: T4 exclusion of canceled issues is per-issue, not blanket"
else
  fail "case16: T4 exclusion of canceled issues is per-issue, not blanket (rc=$rc got: $out)"
fi

# --- case 17: FIX F4 repros (clause-based attribution) -----------------------
# Each of these is a repro named explicitly in the fix: a heuristic based on
# "the segment between this ID and the next" would get at least one of them
# wrong; clause-based attribution (split at , ; | . ) gets all four right.

# 17a: "Done: TECH-1, planned: TECH-2": TECH-1 completed, TECH-2 unstarted
# -> both correctly attributed via the comma-delimited clauses, no fire.
read -r -d '' CASE17A <<'EOF' || true
{
  "doc": {"text": "Done: TECH-1, planned: TECH-2\n", "updatedAt": "2026-09-20T00:00:00Z"},
  "issues": [
    {"id": "TECH-1", "stateType": "completed", "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-09-19T00:00:00Z"},
    {"id": "TECH-2", "stateType": "unstarted", "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-09-19T00:00:00Z"}
  ],
  "options": {"now": "2026-09-24T00:00:00Z"}
}
EOF
run_cs "$CASE17A"
fire=$(jqget "$out" '.fire')
nreasons=$(jqget "$out" '.reasons | length')
if ok_success && [ "$fire" = "false" ] && [ "$nreasons" = "0" ]; then
  pass "case17a: 'Done: TECH-1, planned: TECH-2' with matching states does not fire"
else
  fail "case17a: 'Done: TECH-1, planned: TECH-2' with matching states does not fire (rc=$rc got: $out)"
fi

# 17a-flip: positive control for 17a. Same line, but the two issues' actual
# states are SWAPPED (TECH-1 unstarted, TECH-2 completed), so the doc's
# "Done: TECH-1" and "planned: TECH-2" are now both wrong. If clause
# attribution silently failed (e.g. matched nothing, or attributed both
# words to the same ID), this would go quiet like 17a instead of firing on
# both, so this proves 17a's silence means "correctly matched", not
# "matched nothing".
read -r -d '' CASE17AFLIP <<'EOF' || true
{
  "doc": {"text": "Done: TECH-1, planned: TECH-2\n", "updatedAt": "2026-09-20T00:00:00Z"},
  "issues": [
    {"id": "TECH-1", "stateType": "unstarted", "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-09-19T00:00:00Z"},
    {"id": "TECH-2", "stateType": "completed", "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-09-19T00:00:00Z"}
  ],
  "options": {"now": "2026-09-24T00:00:00Z"}
}
EOF
run_cs "$CASE17AFLIP"
t1_ids_classes=$(jqget "$out" '[.reasons[] | select(.rule=="T1") | .issue + ":" + (.detail | capture("\\((?<c>[a-z]+)\\)").c)] | sort | join(",")')
fire=$(jqget "$out" '.fire')
if ok_success && [ "$fire" = "true" ] && [ "$t1_ids_classes" = "TECH-1:completed,TECH-2:unstarted" ]; then
  pass "case17a-flip: swapped states fire T1 on both TECH-1 (completed) and TECH-2 (unstarted), proving 17a's silence is a correct match, not no match"
else
  fail "case17a-flip: swapped states fire T1 on both TECH-1 (completed) and TECH-2 (unstarted), proving 17a's silence is a correct match, not no match (rc=$rc t1=$t1_ids_classes got: $out)"
fi

# 17b: "TECH-1 done; revisit later": TECH-1 completed -> no fire (the
# semicolon-delimited second clause has no ID in it at all, and "later" is
# no longer a recognized word anyway).
read -r -d '' CASE17B <<'EOF' || true
{
  "doc": {"text": "TECH-1 done; revisit later\n", "updatedAt": "2026-09-20T00:00:00Z"},
  "issues": [{"id": "TECH-1", "stateType": "completed", "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-09-19T00:00:00Z"}],
  "options": {"now": "2026-09-24T00:00:00Z"}
}
EOF
run_cs "$CASE17B"
fire=$(jqget "$out" '.fire')
nreasons=$(jqget "$out" '.reasons | length')
if ok_success && [ "$fire" = "false" ] && [ "$nreasons" = "0" ]; then
  pass "case17b: 'TECH-1 done; revisit later' with TECH-1 completed does not fire"
else
  fail "case17b: 'TECH-1 done; revisit later' with TECH-1 completed does not fire (rc=$rc got: $out)"
fi

# 17b-flip: positive control for 17b. Same line, TECH-1's actual state is now
# started, so "done" in TECH-1's own clause is a real mismatch: proves the
# semicolon-delimited line still finds and classifies TECH-1 correctly, and
# 17b's silence is not simply "the whole line matched nothing".
read -r -d '' CASE17BFLIP <<'EOF' || true
{
  "doc": {"text": "TECH-1 done; revisit later\n", "updatedAt": "2026-09-20T00:00:00Z"},
  "issues": [{"id": "TECH-1", "stateType": "started", "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-09-19T00:00:00Z"}],
  "options": {"now": "2026-09-24T00:00:00Z"}
}
EOF
run_cs "$CASE17BFLIP"
rule=$(jqget "$out" '.reasons[0].rule // "none"')
issue=$(jqget "$out" '.reasons[0].issue // "none"')
detail=$(jqget "$out" '.reasons[0].detail // ""')
fire=$(jqget "$out" '.fire')
if ok_success && [ "$fire" = "true" ] && [ "$rule" = "T1" ] && [ "$issue" = "TECH-1" ] && printf '%s' "$detail" | grep -qF "(completed)"; then
  pass "case17b-flip: TECH-1 actually started fires T1 (completed), proving 17b's silence is a correct match, not no match"
else
  fail "case17b-flip: TECH-1 actually started fires T1 (completed), proving 17b's silence is a correct match, not no match (rc=$rc got: $out)"
fi

# 17c: "TECH-1: build live preview": TECH-1 started -> no fire ("live" and
# "building" were dropped as generic status words per FIX F4, so this clause
# now carries no status evidence at all).
read -r -d '' CASE17C <<'EOF' || true
{
  "doc": {"text": "TECH-1: build live preview\n", "updatedAt": "2026-09-20T00:00:00Z"},
  "issues": [{"id": "TECH-1", "stateType": "started", "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-09-19T00:00:00Z"}],
  "options": {"now": "2026-09-24T00:00:00Z"}
}
EOF
run_cs "$CASE17C"
fire=$(jqget "$out" '.fire')
nreasons=$(jqget "$out" '.reasons | length')
if ok_success && [ "$fire" = "false" ] && [ "$nreasons" = "0" ]; then
  pass "case17c: 'TECH-1: build live preview' with TECH-1 started does not fire"
else
  fail "case17c: 'TECH-1: build live preview' with TECH-1 started does not fire (rc=$rc got: $out)"
fi

# 17c-control: positive control for 17c. Same clause shape and colon
# separator, but "shipped" (still a recognized completed word, unlike the
# dropped "live"/"building") replaces "build live"; against a started issue
# this must fire (completed). Proves 17c is silent because "live" and
# "building" were dropped, not because colon-separated clauses match
# nothing at all.
read -r -d '' CASE17CCTRL <<'EOF' || true
{
  "doc": {"text": "TECH-1: shipped preview\n", "updatedAt": "2026-09-20T00:00:00Z"},
  "issues": [{"id": "TECH-1", "stateType": "started", "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-09-19T00:00:00Z"}],
  "options": {"now": "2026-09-24T00:00:00Z"}
}
EOF
run_cs "$CASE17CCTRL"
rule=$(jqget "$out" '.reasons[0].rule // "none"')
issue=$(jqget "$out" '.reasons[0].issue // "none"')
detail=$(jqget "$out" '.reasons[0].detail // ""')
fire=$(jqget "$out" '.fire')
if ok_success && [ "$fire" = "true" ] && [ "$rule" = "T1" ] && [ "$issue" = "TECH-1" ] && printf '%s' "$detail" | grep -qF "(completed)"; then
  pass "case17c-control: 'TECH-1: shipped preview' vs a started issue fires T1 (completed), proving the clause still matches recognized words"
else
  fail "case17c-control: 'TECH-1: shipped preview' vs a started issue fires T1 (completed), proving the clause still matches recognized words (rc=$rc got: $out)"
fi

# 17d: a markdown table row, "| 3 | Extraction agent | planned (TECH-1317) |"
# TECH-1317 completed -> T1 fires, classified planned (unstarted).
read -r -d '' CASE17D <<'EOF' || true
{
  "doc": {"text": "| 3 | Extraction agent | planned (TECH-1317) |\n", "updatedAt": "2026-09-20T00:00:00Z"},
  "issues": [{"id": "TECH-1317", "stateType": "completed", "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-09-19T00:00:00Z"}],
  "options": {"now": "2026-09-24T00:00:00Z"}
}
EOF
run_cs "$CASE17D"
rule=$(jqget "$out" '.reasons[0].rule // "none"')
issue=$(jqget "$out" '.reasons[0].issue // "none"')
detail=$(jqget "$out" '.reasons[0].detail // ""')
fire=$(jqget "$out" '.fire')
if ok_success && [ "$fire" = "true" ] && [ "$rule" = "T1" ] && [ "$issue" = "TECH-1317" ] && printf '%s' "$detail" | grep -qF "(unstarted)"; then
  pass "case17d: table row 'planned (TECH-1317)' vs completed fires T1, classified unstarted"
else
  fail "case17d: table row 'planned (TECH-1317)' vs completed fires T1, classified unstarted (rc=$rc got: $out)"
fi

# --- case 18: D1 fix (exactly one top-level JSON value on stdin) ------------
# Two concatenated JSON objects bypass validation under jq's default stream
# parsing unless explicitly rejected up front: exit 2, empty stdout, before
# any T1-T4 evaluation runs on either object.

CASE18A_OBJ1='{"doc":{"text":"TECH-1 done\n","updatedAt":"2026-09-01T00:00:00Z"},"issues":[{"id":"TECH-1","stateType":"completed","createdAt":"2026-08-01T00:00:00Z","updatedAt":"2026-08-01T00:00:00Z"}]}'
CASE18A_OBJ2='{"doc":{"text":"TECH-2 done\n","updatedAt":"2026-09-01T00:00:00Z"},"issues":[{"id":"TECH-2","stateType":"completed","createdAt":"2026-08-01T00:00:00Z","updatedAt":"2026-08-01T00:00:00Z"}]}'
out=$(printf '%s%s' "$CASE18A_OBJ1" "$CASE18A_OBJ2" | "$CS" 2>/dev/null)
err=$(printf '%s%s' "$CASE18A_OBJ1" "$CASE18A_OBJ2" | "$CS" 2>&1 1>/dev/null)
rc=$?
if [ "$rc" -eq 2 ] && [ -z "$out" ] && [ -n "$err" ]; then
  pass "case18a: two valid-shaped concatenated JSON objects exit 2 with empty stdout"
else
  fail "case18a: two valid-shaped concatenated JSON objects exit 2 with empty stdout (rc=$rc out='$out' err='$err')"
fi

# case18b: one valid object followed by a structurally invalid one (bad
# stateType) also exits 2 with empty stdout, not a clean result from the
# first object.
CASE18B_OBJ2='{"doc":{"text":"x","updatedAt":"2026-09-01T00:00:00Z"},"issues":[{"id":"BAD-1","stateType":"bogus","createdAt":"2026-08-01T00:00:00Z","updatedAt":"2026-08-01T00:00:00Z"}]}'
out=$(printf '%s%s' "$CASE18A_OBJ1" "$CASE18B_OBJ2" | "$CS" 2>/dev/null)
err=$(printf '%s%s' "$CASE18A_OBJ1" "$CASE18B_OBJ2" | "$CS" 2>&1 1>/dev/null)
rc=$?
if [ "$rc" -eq 2 ] && [ -z "$out" ] && [ -n "$err" ]; then
  pass "case18b: one valid object followed by an invalid object exits 2 with empty stdout"
else
  fail "case18b: one valid object followed by an invalid object exits 2 with empty stdout (rc=$rc out='$out' err='$err')"
fi

# case18c: a single valid top-level object still works (spot check; also
# covered implicitly by every other case in this file).
run_cs "$CASE18A_OBJ1"
fire=$(jqget "$out" '.fire')
nreasons=$(jqget "$out" '.reasons | length')
if ok_success && [ "$fire" = "false" ] && [ "$nreasons" = "0" ]; then
  pass "case18c: a single top-level JSON object still evaluates normally"
else
  fail "case18c: a single top-level JSON object still evaluates normally (rc=$rc got: $out)"
fi

# --- case 19: D2 fix (digit-period exception, single-ID table row) ----------

# 19a: a period between two digits (a version token) is not a clause
# boundary, so "done" stays in TECH-1's clause even after "v1.2".
run_cs '{"doc":{"text":"TECH-1 v1.2 done\n","updatedAt":"2026-09-01T00:00:00Z"},"issues":[{"id":"TECH-1","stateType":"started","createdAt":"2026-08-01T00:00:00Z","updatedAt":"2026-08-01T00:00:00Z"}]}'
rule=$(jqget "$out" '.reasons[0].rule // "none"')
issue=$(jqget "$out" '.reasons[0].issue // "none"')
detail=$(jqget "$out" '.reasons[0].detail // ""')
fire=$(jqget "$out" '.fire')
if ok_success && [ "$fire" = "true" ] && [ "$rule" = "T1" ] && [ "$issue" = "TECH-1" ] && printf '%s' "$detail" | grep -qF "(completed)"; then
  pass "case19a: 'TECH-1 v1.2 done' does not split the clause at the version period, fires T1 (completed)"
else
  fail "case19a: 'TECH-1 v1.2 done' does not split the clause at the version period, fires T1 (completed) (rc=$rc got: $out)"
fi

# 19b: a table row with the ID and status word in different cells still
# attributes the status to the ID when the row references exactly one
# known issue.
run_cs '{"doc":{"text":"| TECH-1 | done |\n","updatedAt":"2026-09-01T00:00:00Z"},"issues":[{"id":"TECH-1","stateType":"started","createdAt":"2026-08-01T00:00:00Z","updatedAt":"2026-08-01T00:00:00Z"}]}'
rule=$(jqget "$out" '.reasons[0].rule // "none"')
issue=$(jqget "$out" '.reasons[0].issue // "none"')
detail=$(jqget "$out" '.reasons[0].detail // ""')
fire=$(jqget "$out" '.fire')
if ok_success && [ "$fire" = "true" ] && [ "$rule" = "T1" ] && [ "$issue" = "TECH-1" ] && printf '%s' "$detail" | grep -qF "(completed)"; then
  pass "case19b: '| TECH-1 | done |' attributes the status cell to the ID cell, fires T1 (completed)"
else
  fail "case19b: '| TECH-1 | done |' attributes the status cell to the ID cell, fires T1 (completed) (rc=$rc got: $out)"
fi

# 19c: same single-ID whole-row rule with a third, unrelated cell in
# between the ID and the status word.
run_cs '{"doc":{"text":"| TECH-1 | Extraction agent | done |\n","updatedAt":"2026-09-01T00:00:00Z"},"issues":[{"id":"TECH-1","stateType":"started","createdAt":"2026-08-01T00:00:00Z","updatedAt":"2026-08-01T00:00:00Z"}]}'
rule=$(jqget "$out" '.reasons[0].rule // "none"')
issue=$(jqget "$out" '.reasons[0].issue // "none"')
detail=$(jqget "$out" '.reasons[0].detail // ""')
fire=$(jqget "$out" '.fire')
if ok_success && [ "$fire" = "true" ] && [ "$rule" = "T1" ] && [ "$issue" = "TECH-1" ] && printf '%s' "$detail" | grep -qF "(completed)"; then
  pass "case19c: '| TECH-1 | Extraction agent | done |' attributes the status cell across an unrelated cell, fires T1 (completed)"
else
  fail "case19c: '| TECH-1 | Extraction agent | done |' attributes the status cell across an unrelated cell, fires T1 (completed) (rc=$rc got: $out)"
fi

# 19d: negative control, restated explicitly for D2: a comma-delimited line
# with two IDs and two matching states still does not fire (already covered
# by case17a; kept here as an explicit D2 regression since D2's own spec
# names it as a case that must still NOT fire after the table-row change).
run_cs '{"doc":{"text":"Done: TECH-1, planned: TECH-2\n","updatedAt":"2026-09-01T00:00:00Z"},"issues":[{"id":"TECH-1","stateType":"completed","createdAt":"2026-08-01T00:00:00Z","updatedAt":"2026-08-01T00:00:00Z"},{"id":"TECH-2","stateType":"unstarted","createdAt":"2026-08-01T00:00:00Z","updatedAt":"2026-08-01T00:00:00Z"}]}'
fire=$(jqget "$out" '.fire')
nreasons=$(jqget "$out" '.reasons | length')
if ok_success && [ "$fire" = "false" ] && [ "$nreasons" = "0" ]; then
  pass "case19d: 'Done: TECH-1, planned: TECH-2' still does not fire after the table-row fix"
else
  fail "case19d: 'Done: TECH-1, planned: TECH-2' still does not fire after the table-row fix (rc=$rc got: $out)"
fi

# 19e: a table row referencing TWO known IDs keeps ordinary per-cell
# attribution instead of the whole-row rule: neither cell alone carries
# both an ID and a status word, so neither ID gets any status evidence and
# the row does not fire, proving the whole-row rule is single-ID only.
run_cs '{"doc":{"text":"| TECH-1 | TECH-2 | done |\n","updatedAt":"2026-09-01T00:00:00Z"},"issues":[{"id":"TECH-1","stateType":"started","createdAt":"2026-08-01T00:00:00Z","updatedAt":"2026-08-01T00:00:00Z"},{"id":"TECH-2","stateType":"started","createdAt":"2026-08-01T00:00:00Z","updatedAt":"2026-08-01T00:00:00Z"}]}'
fire=$(jqget "$out" '.fire')
nreasons=$(jqget "$out" '.reasons | length')
if ok_success && [ "$fire" = "false" ] && [ "$nreasons" = "0" ]; then
  pass "case19e: a two-ID table row keeps per-cell attribution, not the single-ID whole-row rule"
else
  fail "case19e: a two-ID table row keeps per-cell attribution, not the single-ID whole-row rule (rc=$rc got: $out)"
fi

# 19f: a single-ID table row with two DIFFERENT status classes anywhere in
# the row is reported as uncertain (no fire), same as a multi-class clause.
run_cs '{"doc":{"text":"| TECH-1 | in progress | done |\n","updatedAt":"2026-09-01T00:00:00Z"},"issues":[{"id":"TECH-1","stateType":"started","createdAt":"2026-08-01T00:00:00Z","updatedAt":"2026-08-01T00:00:00Z"}]}'
fire=$(jqget "$out" '.fire')
nreasons=$(jqget "$out" '.reasons | length')
if ok_success && [ "$fire" = "false" ] && [ "$nreasons" = "0" ]; then
  pass "case19f: a single-ID table row with two status classes is uncertain, no fire"
else
  fail "case19f: a single-ID table row with two status classes is uncertain, no fire (rc=$rc got: $out)"
fi

# --- case 20: D3 fix (markdown-link vs bare-URL masking) ---------------------

# 20a: a markdown link masks only its parenthesised destination, so text
# right after the closing paren (":done") is still visible as status
# evidence for the ID embedded in the destination.
run_cs '{"doc":{"text":"[ticket](https://example.com/TECH-1):done\n","updatedAt":"2026-09-01T00:00:00Z"},"issues":[{"id":"TECH-1","stateType":"started","createdAt":"2026-08-01T00:00:00Z","updatedAt":"2026-08-01T00:00:00Z"}]}'
rule=$(jqget "$out" '.reasons[0].rule // "none"')
issue=$(jqget "$out" '.reasons[0].issue // "none"')
detail=$(jqget "$out" '.reasons[0].detail // ""')
fire=$(jqget "$out" '.fire')
if ok_success && [ "$fire" = "true" ] && [ "$rule" = "T1" ] && [ "$issue" = "TECH-1" ] && printf '%s' "$detail" | grep -qF "(completed)"; then
  pass "case20a: '[ticket](https://example.com/TECH-1):done' sees text after the link, fires T1 (completed)"
else
  fail "case20a: '[ticket](https://example.com/TECH-1):done' sees text after the link, fires T1 (completed) (rc=$rc got: $out)"
fi

# 20b: a status word genuinely inside a bare URL's path is masked along
# with the rest of the URL and never counts as status evidence.
run_cs '{"doc":{"text":"https://x/done/TECH-1\n","updatedAt":"2026-09-01T00:00:00Z"},"issues":[{"id":"TECH-1","stateType":"started","createdAt":"2026-08-01T00:00:00Z","updatedAt":"2026-08-01T00:00:00Z"}]}'
fire=$(jqget "$out" '.fire')
nreasons=$(jqget "$out" '.reasons | length')
if ok_success && [ "$fire" = "false" ] && [ "$nreasons" = "0" ]; then
  pass "case20b: 'https://x/done/TECH-1' masks the whole URL path, no fire"
else
  fail "case20b: 'https://x/done/TECH-1' masks the whole URL path, no fire (rc=$rc got: $out)"
fi

# 20c: a bare URL followed by a comma-then-status-word does NOT fire: the
# comma is not masked (it is not part of the URL, and is followed by a
# space, so it stays an ordinary clause boundary), so "done" is in the
# clause AFTER the comma, not in TECH-1's own clause, and is correctly not
# attributed to it. This is deliberately no-fire, not fire: the OLD greedy
# `http\S*` mask used to swallow the comma too (no whitespace between
# "TECH-1" and the comma), which merged "done" into TECH-1's clause by
# accident and made this repro fire for the wrong reason.
run_cs '{"doc":{"text":"see https://x/TECH-1, done\n","updatedAt":"2026-09-01T00:00:00Z"},"issues":[{"id":"TECH-1","stateType":"started","createdAt":"2026-08-01T00:00:00Z","updatedAt":"2026-08-01T00:00:00Z"}]}'
fire=$(jqget "$out" '.fire')
nreasons=$(jqget "$out" '.reasons | length')
if ok_success && [ "$fire" = "false" ] && [ "$nreasons" = "0" ]; then
  pass "case20c: 'see https://x/TECH-1, done' does not fire (comma is a real clause boundary, not part of the URL)"
else
  fail "case20c: 'see https://x/TECH-1, done' does not fire (comma is a real clause boundary, not part of the URL) (rc=$rc got: $out)"
fi

# 20d: discriminating two-ID variant of 20c, proving the comma boundary
# actually protects TECH-1's clause rather than merely producing a
# no-fire result by accident: TECH-1's clause (up to the comma) stays
# clean, but TECH-2's clause ("TECH-2 done") correctly fires T1.
run_cs '{"doc":{"text":"see https://x/TECH-1, TECH-2 done\n","updatedAt":"2026-09-01T00:00:00Z"},"issues":[{"id":"TECH-1","stateType":"started","createdAt":"2026-08-01T00:00:00Z","updatedAt":"2026-08-01T00:00:00Z"},{"id":"TECH-2","stateType":"started","createdAt":"2026-08-01T00:00:00Z","updatedAt":"2026-08-01T00:00:00Z"}]}'
n=$(jqget "$out" '.reasons | length')
t1issue=$(jqget "$out" '.reasons[0].issue // "none"')
detail=$(jqget "$out" '.reasons[0].detail // ""')
fire=$(jqget "$out" '.fire')
if ok_success && [ "$fire" = "true" ] && [ "$n" = "1" ] && [ "$t1issue" = "TECH-2" ] && printf '%s' "$detail" | grep -qF "(completed)"; then
  pass "case20d: 'see https://x/TECH-1, TECH-2 done' fires T1 on TECH-2 only, TECH-1's clause stays clean"
else
  fail "case20d: 'see https://x/TECH-1, TECH-2 done' fires T1 on TECH-2 only, TECH-1's clause stays clean (rc=$rc got: $out)"
fi


# --- summary ------------------------------------------------------------------

echo "----"
if [ "$FAILS" -eq 0 ]; then
  echo "ALL PASSED"
  exit 0
else
  echo "$FAILS FAILED"
  exit 1
fi
