#!/usr/bin/env bash
# Regression suite for hooks/track-doc-edits.sh and hooks/check-doc-hygiene.sh.
# Runs both hooks against a throwaway HOME and throwaway project directories,
# feeding them the same JSON shape Claude Code does. Never touches real
# ~/.claude state. Prints PASS/FAIL per case; exits non-zero on any FAIL.

set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd -P)
TRACK="$REPO_ROOT/hooks/track-doc-edits.sh"
STOP="$REPO_ROOT/hooks/check-doc-hygiene.sh"

FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }

# Fresh throwaway HOME for the whole run: real ~/.claude state is never read
# or written by this script.
export HOME
HOME=$(mktemp -d)

# --- helpers -----------------------------------------------------------------

# edit_hook <project_dir> <session_id> <file_path>
# Runs track-doc-edits.sh as PostToolUse would, for an Edit on <file_path>.
edit_hook() {
  local project_dir="$1" session_id="$2" file_path="$3"
  jq -cn --arg sid "$session_id" --arg fp "$file_path" \
    '{session_id:$sid, tool_input:{file_path:$fp}}' \
    | CLAUDE_PROJECT_DIR="$project_dir" bash "$TRACK"
}

# stop_hook <project_dir> <session_id> [stop_hook_active]
# Runs check-doc-hygiene.sh as the Stop hook would. Prints whatever the hook
# emits on stdout (empty string = no reminder).
stop_hook() {
  local project_dir="$1" session_id="$2" active="${3:-false}"
  jq -cn --arg sid "$session_id" --argjson active "$active" \
    '{session_id:$sid, stop_hook_active:$active}' \
    | CLAUDE_PROJECT_DIR="$project_dir" bash "$STOP"
}

new_project() { mktemp -d; }

session_bucket_dir() {
  local project_dir="$1" session_id="$2" hash
  hash=$(printf '%s' "$project_dir" | { shasum 2>/dev/null || sha1sum 2>/dev/null; } | cut -c1-16)
  printf '%s/.claude/document-hygiene/state/%s/sessions/%s\n' "$HOME" "$hash" "$session_id"
}

# --- syntax check --------------------------------------------------------------

if bash -n "$TRACK" && bash -n "$STOP"; then
  pass "bash -n on both hooks"
else
  fail "bash -n on both hooks"
fi

# --- case 1: bare scar word -> Stop emits reminder naming it -----------------

proj=$(new_project)
sid="case1-$$"
doc="$proj/plan.md"
printf '# Plan\n\nTODO fix the thing\n' > "$doc"
edit_hook "$proj" "$sid" "$doc" >/dev/null
out=$(stop_hook "$proj" "$sid")
if [ -n "$out" ] && printf '%s' "$out" | grep -q "$doc" && printf '%s' "$out" | grep -qi 'Drift/changelog markers'; then
  pass "case1: bare scar word triggers reminder naming the doc"
else
  fail "case1: bare scar word triggers reminder naming the doc (got: $out)"
fi

# --- case 2: exempt-after-edit -> Stop emits nothing -------------------------

proj=$(new_project)
sid="case2-$$"
doc="$proj/plan.md"
printf '# Plan\n\nTODO fix the thing\n' > "$doc"
edit_hook "$proj" "$sid" "$doc" >/dev/null
# Doc gets marked exempt after the edit was recorded.
printf '<!-- hygiene: ignore -->\n# Plan\n\nTODO fix the thing\n' > "$doc"
out=$(stop_hook "$proj" "$sid")
if [ -z "$out" ]; then
  pass "case2: exempt-after-edit suppresses the reminder"
else
  fail "case2: exempt-after-edit suppresses the reminder (got: $out)"
fi

# --- case 3: all-targets-exempt (5 edits then marker added) ------------------

proj=$(new_project)
sid="case3-$$"
doc="$proj/plan.md"
printf '# Plan\n\nnothing to see here\n' > "$doc"
for _ in 1 2 3 4 5; do
  edit_hook "$proj" "$sid" "$doc" >/dev/null
done
printf '<!-- hygiene: ignore -->\n# Plan\n\nnothing to see here\n' > "$doc"
out=$(stop_hook "$proj" "$sid")
if [ -z "$out" ]; then
  pass "case3: all-targets-exempt suppresses the reminder"
else
  fail "case3: all-targets-exempt suppresses the reminder (got: $out)"
fi

# --- case 4: project under /tmp is tracked; outside-project temp file is not -

tmp_project=$(mktemp -d "/tmp/dhtest.XXXXXX")
sid="case4-$$"
in_project_doc="$tmp_project/spec.md"
printf '# Spec\n\nnothing scary here\n' > "$in_project_doc"
edit_hook "$tmp_project" "$sid" "$in_project_doc" >/dev/null
bucket=$(session_bucket_dir "$tmp_project" "$sid")
count_after_in=$(cat "$bucket/edit-count" 2>/dev/null || echo 0)

outside_doc=$(mktemp -u "/var/folders/dhtest.XXXXXX" 2>/dev/null)
if [ -z "$outside_doc" ] || [[ "$outside_doc" != /var/folders/* ]]; then
  # /var/folders may not exist/be writable on this platform (non-macOS), so
  # fall back to another temp root outside the project that the hook also
  # excludes, so the case still tests "outside project, under a temp dir".
  outside_doc=$(mktemp -u "/tmp/dhtest-outside.XXXXXX")
fi
outside_doc="${outside_doc}.md"
printf '# Outside\n\nnothing scary here\n' > "$outside_doc"
edit_hook "$tmp_project" "$sid" "$outside_doc" >/dev/null
count_after_outside=$(cat "$bucket/edit-count" 2>/dev/null || echo 0)
rm -f "$outside_doc"

if [ "$count_after_in" = "1" ] && [ "$count_after_outside" = "$count_after_in" ]; then
  pass "case4: project under /tmp is tracked; outside-project temp file is not"
else
  fail "case4: project under /tmp is tracked; outside-project temp file is not (in=$count_after_in outside=$count_after_outside)"
fi
rm -rf "$tmp_project"

# --- case 5: stop_hook_active=true -> no emission, bucket gone ---------------

proj=$(new_project)
sid="case5-$$"
doc="$proj/plan.md"
printf '# Plan\n\nTODO fix the thing\n' > "$doc"
edit_hook "$proj" "$sid" "$doc" >/dev/null
bucket=$(session_bucket_dir "$proj" "$sid")
out=$(stop_hook "$proj" "$sid" true)
if [ -z "$out" ] && [ ! -d "$bucket" ]; then
  pass "case5: stop_hook_active=true suppresses reminder and clears the bucket"
else
  fail "case5: stop_hook_active=true suppresses reminder and clears the bucket (out='$out', bucket exists=$([ -d "$bucket" ] && echo yes || echo no))"
fi

# --- case 6: TODO(reason) is not a scar; bare TODO is ------------------------

proj=$(new_project)
sid="case6-$$"
justified="$proj/justified.md"
bare="$proj/bare.md"
printf '# Doc\n\nTODO(keep until v2 ships) revisit this\n' > "$justified"
printf '# Doc\n\nTODO revisit this\n' > "$bare"
edit_hook "$proj" "$sid" "$justified" >/dev/null
edit_hook "$proj" "$sid" "$bare" >/dev/null
bucket=$(session_bucket_dir "$proj" "$sid")
scarred_file="$bucket/scarred-docs"
justified_scarred="no"; bare_scarred="no"
[ -f "$scarred_file" ] && grep -qxF "$justified" "$scarred_file" && justified_scarred="yes"
[ -f "$scarred_file" ] && grep -qxF "$bare" "$scarred_file" && bare_scarred="yes"
if [ "$justified_scarred" = "no" ] && [ "$bare_scarred" = "yes" ]; then
  pass "case6: TODO(reason) is not a scar; bare TODO is"
else
  fail "case6: TODO(reason) is not a scar; bare TODO is (justified_scarred=$justified_scarred bare_scarred=$bare_scarred)"
fi

# --- case 7: mode resolution order -------------------------------------------

# 7a: default (no mode files) -> propose
proj=$(new_project)
sid="case7a-$$"
doc="$proj/plan.md"
printf '# Plan\n\nTODO fix the thing\n' > "$doc"
edit_hook "$proj" "$sid" "$doc" >/dev/null
unset DOCUMENT_HYGIENE_MODE
out=$(stop_hook "$proj" "$sid")
if printf '%s' "$out" | grep -q 'Mode: propose'; then
  pass "case7a: default mode is propose"
else
  fail "case7a: default mode is propose (got: $out)"
fi

# 7b: global file -> apply
proj=$(new_project)
sid="case7b-$$"
doc="$proj/plan.md"
printf '# Plan\n\nTODO fix the thing\n' > "$doc"
edit_hook "$proj" "$sid" "$doc" >/dev/null
mkdir -p "$HOME/.claude/document-hygiene"
printf 'apply\n' > "$HOME/.claude/document-hygiene/mode"
out=$(stop_hook "$proj" "$sid")
if printf '%s' "$out" | grep -q 'Mode: apply'; then
  pass "case7b: global mode file selects apply"
else
  fail "case7b: global mode file selects apply (got: $out)"
fi

# 7c: project file beats global file
proj=$(new_project)
sid="case7c-$$"
doc="$proj/plan.md"
printf '# Plan\n\nTODO fix the thing\n' > "$doc"
edit_hook "$proj" "$sid" "$doc" >/dev/null
# Global file still says apply from 7b; project file says propose and must win.
mkdir -p "$proj/.claude/.hygiene"
printf 'propose\n' > "$proj/.claude/.hygiene/mode"
out=$(stop_hook "$proj" "$sid")
if printf '%s' "$out" | grep -q 'Mode: propose'; then
  pass "case7c: project mode file beats global mode file"
else
  fail "case7c: project mode file beats global mode file (got: $out)"
fi

# 7d: env var beats project file
proj=$(new_project)
sid="case7d-$$"
doc="$proj/plan.md"
printf '# Plan\n\nTODO fix the thing\n' > "$doc"
edit_hook "$proj" "$sid" "$doc" >/dev/null
mkdir -p "$proj/.claude/.hygiene"
printf 'propose\n' > "$proj/.claude/.hygiene/mode"
out=$(jq -cn --arg sid "$sid" '{session_id:$sid, stop_hook_active:false}' \
  | DOCUMENT_HYGIENE_MODE=apply CLAUDE_PROJECT_DIR="$proj" bash "$STOP")
if printf '%s' "$out" | grep -q 'Mode: apply'; then
  pass "case7d: env var beats project mode file"
else
  fail "case7d: env var beats project mode file (got: $out)"
fi

# --- case 8: fewer than 5 edits, no scars -> nothing emitted -----------------

proj=$(new_project)
sid="case8-$$"
doc="$proj/plan.md"
printf '# Plan\n\nall clean, nothing to flag\n' > "$doc"
edit_hook "$proj" "$sid" "$doc" >/dev/null
edit_hook "$proj" "$sid" "$doc" >/dev/null
out=$(stop_hook "$proj" "$sid")
if [ -z "$out" ]; then
  pass "case8: fewer than 5 edits with no scars emits nothing"
else
  fail "case8: fewer than 5 edits with no scars emits nothing (got: $out)"
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
