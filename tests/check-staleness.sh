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
CS="$REPO_ROOT/bin/check-staleness"

FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }

# run_cs <json>: runs check-staleness on the given JSON, prints its stdout,
# and sets $CS_RC to its exit code (checked by callers via $?  semantics
# through a captured variable, since this runs in the current shell).
run_cs() {
  printf '%s' "$1" | "$CS"
}
run_cs_quiet() {
  printf '%s' "$1" | "$CS" --quiet
}

jqget() {
  # jqget <json-output> <filter>
  printf '%s' "$1" | jq -r "$2" 2>/dev/null
}

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
out=$(run_cs "$CASE1")
fire=$(jqget "$out" '.fire')
rules=$(jqget "$out" '[.reasons[].rule] | unique | sort | join(",")')
if [ "$fire" = "true" ] && [ "$rules" = "T1,T2,T4" ]; then
  pass "case1: 2026-09-24 reconstruction fires T1+T2+T4, not T3"
else
  fail "case1: 2026-09-24 reconstruction fires T1+T2+T4, not T3 (fire=$fire rules=$rules out=$out)"
fi

# --- case 2: a current doc -> no fire ----------------------------------------

read -r -d '' CASE2 <<'EOF' || true
{
  "doc": {"text": "# Status\n\n- TECH-1: done\n", "updatedAt": "2026-09-23T12:00:00Z"},
  "issues": [{"id": "TECH-1", "stateType": "completed", "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-09-23T11:00:00Z"}],
  "options": {"now": "2026-09-24T00:00:00Z"}
}
EOF
out=$(run_cs "$CASE2")
fire=$(jqget "$out" '.fire')
if [ "$fire" = "false" ]; then
  pass "case2: current doc does not fire"
else
  fail "case2: current doc does not fire (got: $out)"
fi

# --- case 3: T1 word-class mismatch, one per class ---------------------------

check_t1_class() {
  # check_t1_class <label> <line_word> <actual_stateType> <expected_detail_word>
  label="$1"; word="$2"; state="$3"
  json=$(printf '{"doc":{"text":"- TICK-1: %s\\n","updatedAt":"2026-09-20T00:00:00Z"},"issues":[{"id":"TICK-1","stateType":"%s","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-09-21T00:00:00Z"}],"options":{"now":"2026-09-24T00:00:00Z"}}' "$word" "$state")
  out=$(run_cs "$json")
  rule=$(jqget "$out" '.reasons[0].rule // "none"')
  if [ "$rule" = "T1" ]; then
    pass "case3 ($label): '$word' vs stateType=$state fires T1"
  else
    fail "case3 ($label): '$word' vs stateType=$state fires T1 (got: $out)"
  fi
}
# unstarted word, issue actually completed
check_t1_class "unstarted-word" "planned" "completed"
# started word, issue actually completed
check_t1_class "started-word" "in progress" "completed"
# completed word, issue actually started
check_t1_class "completed-word" "done" "started"

# A word from every unstarted synonym should classify as unstarted (spot check
# a few, not just "planned"): backlog, not yet, upcoming, later, todo, to do.
for w in "backlog" "not yet" "upcoming" "later" "todo" "to do" "not started"; do
  json=$(printf '{"doc":{"text":"- TICK-1: %s\\n","updatedAt":"2026-09-20T00:00:00Z"},"issues":[{"id":"TICK-1","stateType":"completed","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-09-21T00:00:00Z"}],"options":{"now":"2026-09-24T00:00:00Z"}}' "$w")
  out=$(run_cs "$json")
  rule=$(jqget "$out" '.reasons[0].rule // "none"')
  if [ "$rule" = "T1" ]; then
    pass "case3 (unstarted synonym '$w'): classified unstarted, mismatches completed"
  else
    fail "case3 (unstarted synonym '$w'): classified unstarted, mismatches completed (got: $out)"
  fi
done

# --- case 4: T1b, no status word anywhere for the issue ----------------------

read -r -d '' CASE4 <<'EOF' || true
{
  "doc": {"text": "See TICK-9 for details.\n", "updatedAt": "2026-09-23T00:00:00Z"},
  "issues": [{"id": "TICK-9", "stateType": "started", "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-09-23T20:00:00Z"}],
  "options": {"now": "2026-09-24T00:00:00Z"}
}
EOF
out=$(run_cs "$CASE4")
rule=$(jqget "$out" '.reasons[0].rule // "none"')
if [ "$rule" = "T1b" ]; then
  pass "case4: no status word + issue updated after doc fires T1b"
else
  fail "case4: no status word + issue updated after doc fires T1b (got: $out)"
fi

# case 4b: T1b is suppressed when ANOTHER line about the same issue does carry
# a (matching) status word -- one reason per issue, not per line.
read -r -d '' CASE4B <<'EOF' || true
{
  "doc": {"text": "See TICK-9 for details.\nTICK-9 is in progress.\n", "updatedAt": "2026-09-23T00:00:00Z"},
  "issues": [{"id": "TICK-9", "stateType": "started", "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-09-23T20:00:00Z"}],
  "options": {"now": "2026-09-24T00:00:00Z"}
}
EOF
out=$(run_cs "$CASE4B")
fire=$(jqget "$out" '.fire')
if [ "$fire" = "false" ]; then
  pass "case4b: T1b suppressed when another line about the same issue has a matching status word"
else
  fail "case4b: T1b suppressed when another line about the same issue has a matching status word (got: $out)"
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
out=$(run_cs "$CASE4C")
n=$(jqget "$out" '[.reasons[] | select(.rule=="T1b")] | length')
if [ "$n" = "1" ]; then
  pass "case4c: T1b fires exactly once per issue, not once per referencing line"
else
  fail "case4c: T1b fires exactly once per issue, not once per referencing line (count=$n, out=$out)"
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
out=$(run_cs "$json")
has_t2=$(jqget "$out" '[.reasons[] | select(.rule=="T2")] | length')
if [ "$has_t2" = "1" ]; then
  pass "case5: 5 issues updated since doc meets the default volume threshold"
else
  fail "case5: 5 issues updated since doc meets the default volume threshold (got: $out)"
fi

issues4=$(build_issues 4)
json=$(printf '{"doc":{"text":"nothing here\\n","updatedAt":"2026-09-20T00:00:00Z"},"issues":%s,"options":{"now":"2026-09-24T00:00:00Z"}}' "$issues4")
out=$(run_cs "$json")
fire=$(jqget "$out" '.fire')
if [ "$fire" = "false" ]; then
  pass "case5b: 4 issues (below threshold) does not fire"
else
  fail "case5b: 4 issues (below threshold) does not fire (got: $out)"
fi

# --- case 6: T3 age, active vs inactive project ------------------------------

read -r -d '' CASE6A <<'EOF' || true
{
  "doc": {"text": "nothing here\n", "updatedAt": "2026-09-01T00:00:00Z"},
  "issues": [{"id": "AGE-1", "stateType": "started", "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-09-22T00:00:00Z"}],
  "options": {"now": "2026-09-24T00:00:00Z"}
}
EOF
out=$(run_cs "$CASE6A")
has_t3=$(jqget "$out" '[.reasons[] | select(.rule=="T3")] | length')
if [ "$has_t3" = "1" ]; then
  pass "case6a: old doc + active project fires T3"
else
  fail "case6a: old doc + active project fires T3 (got: $out)"
fi

read -r -d '' CASE6B <<'EOF' || true
{
  "doc": {"text": "nothing here\n", "updatedAt": "2026-09-01T00:00:00Z"},
  "issues": [{"id": "AGE-1", "stateType": "started", "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-02T00:00:00Z"}],
  "options": {"now": "2026-09-24T00:00:00Z"}
}
EOF
out=$(run_cs "$CASE6B")
fire=$(jqget "$out" '.fire')
if [ "$fire" = "false" ]; then
  pass "case6b: old doc + inactive project does not fire"
else
  fail "case6b: old doc + inactive project does not fire (got: $out)"
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
out=$(run_cs "$CASE7")
fire=$(jqget "$out" '.fire')
counts=$(jqget "$out" '.counts.changedSinceDoc, .counts.newUnreferenced' | tr '\n' ' ')
if [ "$fire" = "false" ] && [ "$counts" = "0 0 " ]; then
  pass "case7: canceled issues are excluded from T2/T4 counts and don't fire"
else
  fail "case7: canceled issues are excluded from T2/T4 counts and don't fire (fire=$fire counts='$counts' out=$out)"
fi

# --- case 8: an ID embedded inside a URL is still matched --------------------

read -r -d '' CASE8 <<'EOF' || true
{
  "doc": {"text": "See https://example.com/issue/TECH-1317/ for planned work.\n", "updatedAt": "2026-09-20T00:00:00Z"},
  "issues": [{"id": "TECH-1317", "stateType": "completed", "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-09-21T00:00:00Z"}],
  "options": {"now": "2026-09-24T00:00:00Z"}
}
EOF
out=$(run_cs "$CASE8")
rule=$(jqget "$out" '.reasons[0].rule // "none"')
if [ "$rule" = "T1" ]; then
  pass "case8: an ID embedded in a URL is matched and classified"
else
  fail "case8: an ID embedded in a URL is matched and classified (got: $out)"
fi

# T4 should also see an ID inside a URL as "referenced" (i.e. NOT unreferenced).
read -r -d '' CASE8B <<'EOF' || true
{
  "doc": {"text": "Tracking at https://example.com/issue/TECH-9999/\n", "updatedAt": "2026-09-20T00:00:00Z"},
  "issues": [{"id": "TECH-9999", "stateType": "unstarted", "createdAt": "2026-09-21T00:00:00Z", "updatedAt": "2026-09-21T00:00:00Z"}],
  "options": {"now": "2026-09-24T00:00:00Z"}
}
EOF
out=$(run_cs "$CASE8B")
newunref=$(jqget "$out" '.counts.newUnreferenced')
if [ "$newunref" = "0" ]; then
  pass "case8b: an ID inside a URL counts as referenced for T4"
else
  fail "case8b: an ID inside a URL counts as referenced for T4 (got: $out)"
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
out=$(run_cs "$CASE9")
fire=$(jqget "$out" '.fire')
if [ "$fire" = "false" ]; then
  pass "case9: a two-ID line classifies each ID against its own segment (no cross-contamination)"
else
  fail "case9: a two-ID line classifies each ID against its own segment (no cross-contamination) (got: $out)"
fi

# case9b: the mismatching half of a two-ID line still fires T1, proving the
# segmentation isn't just suppressing everything on a multi-ID line.
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
out=$(run_cs "$CASE9B")
t1issue=$(jqget "$out" '.reasons[0].issue // "none"')
n=$(jqget "$out" '.reasons | length')
if [ "$n" = "1" ] && [ "$t1issue" = "TECH-1" ]; then
  pass "case9b: only the actually-mismatched ID on a multi-ID line fires T1"
else
  fail "case9b: only the actually-mismatched ID on a multi-ID line fires T1 (got: $out)"
fi

# --- case 10: the `now` override is honored ----------------------------------

read -r -d '' CASE10 <<'EOF' || true
{
  "doc": {"text": "nothing here\n", "updatedAt": "2026-09-01T00:00:00Z"},
  "issues": [{"id": "NOW-1", "stateType": "started", "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-09-01T01:00:00Z"}],
  "options": {"now": "2026-09-02T00:00:00Z"}
}
EOF
out=$(run_cs "$CASE10")
docage=$(jqget "$out" '.counts.docAgeDays')
if [ "$docage" = "1" ]; then
  pass "case10: options.now overrides the wall-clock date used for docAgeDays"
else
  fail "case10: options.now overrides the wall-clock date used for docAgeDays (got: $out)"
fi

# case10b: with no `now` override, docAgeDays is computed against the real
# wall clock (loosely checked: a doc from over a year ago is definitely old).
read -r -d '' CASE10B <<'EOF' || true
{
  "doc": {"text": "nothing here\n", "updatedAt": "2020-01-01T00:00:00Z"},
  "issues": []
}
EOF
out=$(run_cs "$CASE10B")
docage=$(jqget "$out" '.counts.docAgeDays')
if [ "${docage:-0}" -gt 300 ] 2>/dev/null; then
  pass "case10b: with no options.now, docAgeDays is computed against the real wall clock"
else
  fail "case10b: with no options.now, docAgeDays is computed against the real wall clock (got: $out)"
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

# --- case 12: --quiet prints only fire/no fire -------------------------------

out=$(run_cs_quiet "$CASE1")
if [ "$out" = "fire" ]; then
  pass "case12: --quiet prints 'fire' for a firing case"
else
  fail "case12: --quiet prints 'fire' for a firing case (got: '$out')"
fi

out=$(run_cs_quiet "$CASE2")
if [ "$out" = "no fire" ]; then
  pass "case12b: --quiet prints 'no fire' for a clean case"
else
  fail "case12b: --quiet prints 'no fire' for a clean case (got: '$out')"
fi

# --- case 13: date-format equivalence (Z, fractional seconds, UTC offset) ---
# All four represent the same instant; a T1 firing on one must fire on all,
# with the identical docAgeDays in the output (a positive control: proves the
# comparison isn't silently always-true or always-false regardless of format).

same_instant_docage() {
  ts="$1"
  json=$(printf '{"doc":{"text":"nothing here\\n","updatedAt":"%s"},"issues":[],"options":{"now":"2026-09-24T00:00:00Z"}}' "$ts")
  run_cs "$json" | jq -r '.counts.docAgeDays'
}
d1=$(same_instant_docage "2026-09-01T00:00:00Z")
d2=$(same_instant_docage "2026-09-01T00:00:00.999Z")
d3=$(same_instant_docage "2026-09-01T02:00:00+02:00")
d4=$(same_instant_docage "2026-08-31T22:00:00-02:00")
if [ "$d1" = "$d2" ] && [ "$d1" = "$d3" ] && [ "$d1" = "$d4" ]; then
  pass "case13: Z, fractional-seconds, and +/- UTC offset forms of the same instant agree (docAgeDays=$d1)"
else
  fail "case13: Z, fractional-seconds, and +/- UTC offset forms of the same instant agree (d1=$d1 d2=$d2 d3=$d3 d4=$d4)"
fi

# Re-run the same equivalence under a DST-observing timezone: the comparisons
# must all happen in jq against ISO instants, never against the shell's local
# time, so TZ must not change the answer.
tz_json='{"doc":{"text":"x","updatedAt":"2026-09-01T00:00:00Z"},"issues":[],"options":{"now":"2026-09-24T00:00:00Z"}}'
e_budapest=$(printf '%s' "$tz_json" | TZ=Europe/Budapest "$CS" | jq -r '.counts.docAgeDays')
e_default=$(printf '%s' "$tz_json" | "$CS" | jq -r '.counts.docAgeDays')
if [ "$e_budapest" = "$e_default" ]; then
  pass "case13b: TZ=Europe/Budapest (DST) does not change docAgeDays vs. the default timezone"
else
  fail "case13b: TZ=Europe/Budapest (DST) does not change docAgeDays vs. the default timezone (budapest=$e_budapest default=$e_default)"
fi

# --- case 14: a positive control straddling doc.updatedAt exactly -----------
# One issue 30 minutes before doc.updatedAt (must NOT count as changed-since-
# doc), one 30 minutes after (must count). Proves the ">" boundary isn't
# silently inverted or off by a wide margin.

read -r -d '' CASE14 <<'EOF' || true
{
  "doc": {"text": "nothing here\n", "updatedAt": "2026-09-20T12:00:00Z"},
  "issues": [
    {"id": "EDGE-BEFORE", "stateType": "started", "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-09-20T11:30:00Z"},
    {"id": "EDGE-AFTER",  "stateType": "started", "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-09-20T12:30:00Z"}
  ],
  "options": {"now": "2026-09-24T00:00:00Z"}
}
EOF
out=$(run_cs "$CASE14")
changed=$(jqget "$out" '.counts.changedSinceDoc')
if [ "$changed" = "1" ]; then
  pass "case14: an issue 30 minutes before doc.updatedAt is excluded, one 30 minutes after is included"
else
  fail "case14: an issue 30 minutes before doc.updatedAt is excluded, one 30 minutes after is included (got: $out)"
fi

# --- case 15: jq missing from PATH exits 2 with a message -------------------
# Built the same way tests/run.sh proves the hooks' own jq-missing branch: a
# PATH that genuinely cannot resolve jq, not merely a PATH override that
# hides a working jq.

build_restricted_path_no_jq() {
  d=$(mktemp -d)
  for b in cat mktemp rm bash; do
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
out=$(run_cs "$CASE16")
t4issues=$(jqget "$out" '[.reasons[] | select(.rule=="T4") | .issue] | join(",")')
if [ "$t4issues" = "MIX-2" ]; then
  pass "case16: T4 exclusion of canceled issues is per-issue, not blanket"
else
  fail "case16: T4 exclusion of canceled issues is per-issue, not blanket (got: $out)"
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
