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

# Isolate git calls (recovery-baseline tests) from any real system gitconfig
# (e.g. commit signing), without touching real global config either: HOME
# already points at the throwaway dir, so global config lands there too.
export GIT_CONFIG_SYSTEM=/dev/null

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

# --- SKILL.md frontmatter is valid YAML --------------------------------------
# Regression test for the invalid-YAML frontmatter bug (a plain scalar with
# "days: to fact-check" broke Ruby's YAML parser). Prefer ruby, then python3,
# and SKIP (not FAIL) when neither is available.
skill_md="$REPO_ROOT/skills/document-hygiene/SKILL.md"
fm_file=$(mktemp)
awk '/^---$/{c++; if (c==1) next; if (c==2) exit} c==1' "$skill_md" > "$fm_file"
if command -v ruby >/dev/null 2>&1; then
  if ruby -ryaml -e 'YAML.load_file(ARGV[0])' "$fm_file" >/dev/null 2>&1; then
    pass "SKILL.md frontmatter parses as YAML (ruby)"
  else
    fail "SKILL.md frontmatter parses as YAML (ruby)"
  fi
elif command -v python3 >/dev/null 2>&1; then
  py_err=$(python3 -c 'import yaml, sys; yaml.safe_load(open(sys.argv[1]))' "$fm_file" 2>&1)
  py_rc=$?
  if [ "$py_rc" -eq 0 ]; then
    pass "SKILL.md frontmatter parses as YAML (python3)"
  elif printf '%s' "$py_err" | grep -qi 'no module named'; then
    echo "SKIP: SKILL.md frontmatter YAML check (no ruby, and python3 has no pyyaml)"
  else
    fail "SKILL.md frontmatter parses as YAML (python3): $py_err"
  fi
else
  echo "SKIP: SKILL.md frontmatter YAML check (no ruby or python3 available)"
fi
rm -f "$fm_file"

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

# --- case 9: subagent tool call (agent_id present) is not tracked ------------

proj=$(new_project)
sid="case9-$$"
doc="$proj/plan.md"
printf '# Plan\n\nTODO fix the thing\n' > "$doc"
jq -cn --arg sid "$sid" --arg fp "$doc" --arg aid "sub-1" \
  '{session_id:$sid, agent_id:$aid, tool_input:{file_path:$fp}}' \
  | CLAUDE_PROJECT_DIR="$proj" bash "$TRACK" >/dev/null
bucket=$(session_bucket_dir "$proj" "$sid")
if [ ! -d "$bucket" ]; then
  pass "case9: subagent tool call (agent_id present) is not tracked"
else
  fail "case9: subagent tool call (agent_id present) is not tracked (bucket created at $bucket)"
fi

# --- case 10: missing session_id is not tracked ------------------------------

proj=$(new_project)
doc="$proj/plan.md"
printf '# Plan\n\nTODO fix the thing\n' > "$doc"
state_root="$HOME/.claude/document-hygiene/state"
before=$(find "$state_root" -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
jq -cn --arg fp "$doc" '{tool_input:{file_path:$fp}}' \
  | CLAUDE_PROJECT_DIR="$proj" bash "$TRACK" >/dev/null
after=$(find "$state_root" -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
if [ "$before" = "$after" ]; then
  pass "case10: missing session_id is not tracked"
else
  fail "case10: missing session_id is not tracked (dir count before=$before after=$after)"
fi

# --- case 11: symlinked project root is still tracked as in-project ---------
# Rooted under /tmp (not the default mktemp TMPDIR, which on macOS is under
# /var/folders/... and would land the doc under /private/var/folders/... once
# resolved -- a path the temp/cache skip-pattern list doesn't cover, which
# would mask this exact bug by accident). /tmp -> /private/tmp is covered.

real_dir=$(mktemp -d "/tmp/dhtest-symlink-src.XXXXXX")
link_dir="${real_dir}-link"
ln -s "$real_dir" "$link_dir"
sid="case11-$$"
doc="$link_dir/plan.md"
printf '# Plan\n\nnothing scary here\n' > "$doc"
edit_hook "$link_dir" "$sid" "$doc" >/dev/null
bucket=$(session_bucket_dir "$link_dir" "$sid")
count=$(cat "$bucket/edit-count" 2>/dev/null || echo 0)
if [ "$count" = "1" ]; then
  pass "case11: symlinked project root tracks an in-project file"
else
  fail "case11: symlinked project root tracks an in-project file (count=$count)"
fi
rm -f "$link_dir"
rm -rf "$real_dir"

# --- case 12 (macOS only): PROJECT_DIR=/tmp itself tracks a file under /tmp -
# Regression case for the canon_path bug where PROJECT_DIR=/tmp canonicalized
# to "//tmp" (a "//basename" artifact), never matching a file's canonical
# "/private/tmp/..." path, so the file was silently skipped as scratch.

if [ "$(uname)" = "Darwin" ]; then
  sid="case12-$$"
  doc="/tmp/dhtest-case12-$$.md"
  printf '# Plan\n\nnothing scary here\n' > "$doc"
  edit_hook "/tmp" "$sid" "$doc" >/dev/null
  bucket=$(session_bucket_dir "/tmp" "$sid")
  count=$(cat "$bucket/edit-count" 2>/dev/null || echo 0)
  rm -f "$doc"
  if [ "$count" = "1" ]; then
    pass "case12: PROJECT_DIR=/tmp directly tracks a file under /tmp"
  else
    fail "case12: PROJECT_DIR=/tmp directly tracks a file under /tmp (count=$count)"
  fi
else
  echo "SKIP: case12 (PROJECT_DIR=/tmp direct canonicalization is macOS-specific)"
fi

# --- case 13/14: mode-file whitespace corruption fails closed ---------------
# Regression for `tr -d '[:space:]'` stripping ALL whitespace, which turned a
# corrupted "ap<newline>ply" into "apply" instead of failing to "propose".

proj=$(new_project)
sid="case13-$$"
doc="$proj/plan.md"
printf '# Plan\n\nTODO fix the thing\n' > "$doc"
edit_hook "$proj" "$sid" "$doc" >/dev/null
mkdir -p "$proj/.claude/.hygiene"
printf 'ap\nply' > "$proj/.claude/.hygiene/mode"
out=$(stop_hook "$proj" "$sid")
if printf '%s' "$out" | grep -q 'Mode: propose'; then
  pass "case13: mode file 'ap<newline>ply' fails closed to propose"
else
  fail "case13: mode file 'ap<newline>ply' fails closed to propose (got: $out)"
fi

proj=$(new_project)
sid="case14-$$"
doc="$proj/plan.md"
printf '# Plan\n\nTODO fix the thing\n' > "$doc"
edit_hook "$proj" "$sid" "$doc" >/dev/null
mkdir -p "$proj/.claude/.hygiene"
printf 'apply\n' > "$proj/.claude/.hygiene/mode"
out=$(stop_hook "$proj" "$sid")
if printf '%s' "$out" | grep -q 'Mode: apply'; then
  pass "case14: mode file 'apply<newline>' resolves to apply"
else
  fail "case14: mode file 'apply<newline>' resolves to apply (got: $out)"
fi

# --- case 15/16: track-doc-edits.sh ignore-glob directory-prefix syntax -----

proj=$(new_project)
sid="case15-$$"
mkdir -p "$proj/docs/audit" "$proj/.claude/.hygiene"
printf 'docs/audit/*\n' > "$proj/.claude/.hygiene/ignore"
doc="$proj/docs/audit/notes.md"
printf '# Notes\n\nnothing scary\n' > "$doc"
edit_hook "$proj" "$sid" "$doc" >/dev/null
bucket=$(session_bucket_dir "$proj" "$sid")
if [ ! -d "$bucket" ]; then
  pass "case15: track-doc-edits.sh exempts docs/audit/* via project-relative glob"
else
  fail "case15: track-doc-edits.sh exempts docs/audit/* via project-relative glob (bucket created)"
fi

proj=$(new_project)
sid="case16-$$"
mkdir -p "$proj/docs/audit" "$proj/.claude/.hygiene"
printf 'docs/audit/\n' > "$proj/.claude/.hygiene/ignore"
doc="$proj/docs/audit/notes.md"
printf '# Notes\n\nnothing scary\n' > "$doc"
edit_hook "$proj" "$sid" "$doc" >/dev/null
bucket=$(session_bucket_dir "$proj" "$sid")
if [ ! -d "$bucket" ]; then
  pass "case16: track-doc-edits.sh exempts docs/audit/ directory-prefix pattern"
else
  fail "case16: track-doc-edits.sh exempts docs/audit/ directory-prefix pattern (bucket created)"
fi

# --- case 17/18: check-doc-hygiene.sh ignore-glob directory-prefix syntax ---

proj=$(new_project)
sid="case17-$$"
mkdir -p "$proj/docs/audit"
doc="$proj/docs/audit/notes.md"
printf '# Notes\n\nTODO fix\n' > "$doc"
edit_hook "$proj" "$sid" "$doc" >/dev/null
mkdir -p "$proj/.claude/.hygiene"
printf 'docs/audit/*\n' > "$proj/.claude/.hygiene/ignore"
out=$(stop_hook "$proj" "$sid")
if [ -z "$out" ]; then
  pass "case17: check-doc-hygiene.sh exempts docs/audit/* via project-relative glob"
else
  fail "case17: check-doc-hygiene.sh exempts docs/audit/* via project-relative glob (got: $out)"
fi

proj=$(new_project)
sid="case18-$$"
mkdir -p "$proj/docs/audit"
doc="$proj/docs/audit/notes.md"
printf '# Notes\n\nTODO fix\n' > "$doc"
edit_hook "$proj" "$sid" "$doc" >/dev/null
mkdir -p "$proj/.claude/.hygiene"
printf 'docs/audit/\n' > "$proj/.claude/.hygiene/ignore"
out=$(stop_hook "$proj" "$sid")
if [ -z "$out" ]; then
  pass "case18: check-doc-hygiene.sh exempts docs/audit/ directory-prefix pattern"
else
  fail "case18: check-doc-hygiene.sh exempts docs/audit/ directory-prefix pattern (got: $out)"
fi

# --- case 19: apply-mode recovery baseline: restore line + propose-only -----

if command -v git >/dev/null 2>&1; then
  proj=$(new_project)
  sid="case19-$$"
  git -C "$proj" init -q
  git -C "$proj" config user.email "test@example.com"
  git -C "$proj" config user.name "Test"
  printf '# Committed\n\nTODO fix\n' > "$proj/committed.md"
  git -C "$proj" add committed.md
  git -C "$proj" -c commit.gpgsign=false commit -q -m init
  printf '# Dirty\n\nTODO fix\n' > "$proj/dirty.md"
  git -C "$proj" add dirty.md
  git -C "$proj" -c commit.gpgsign=false commit -q -m init2
  # Leave dirty.md with an uncommitted modification.
  printf '# Dirty\n\nTODO fix, edited\n' > "$proj/dirty.md"

  edit_hook "$proj" "$sid" "$proj/committed.md" >/dev/null
  edit_hook "$proj" "$sid" "$proj/dirty.md" >/dev/null
  out=$(jq -cn --arg sid "$sid" '{session_id:$sid, stop_hook_active:false}' \
    | DOCUMENT_HYGIENE_MODE=apply CLAUDE_PROJECT_DIR="$proj" bash "$STOP")

  ok_restore="no"; ok_propose="no"
  printf '%s' "$out" | grep -q 'restore: git -C' && printf '%s' "$out" | grep -q -- '-- committed.md' && ok_restore="yes"
  printf '%s' "$out" | grep -q 'dirty.md: not committed and clean, propose only' && ok_propose="yes"
  if [ "$ok_restore" = "yes" ] && [ "$ok_propose" = "yes" ]; then
    pass "case19: apply-mode reminder prints a restore line for a clean doc, propose-only for a dirty doc"
  else
    fail "case19: apply-mode reminder prints a restore line for a clean doc, propose-only for a dirty doc (got: $out)"
  fi
else
  echo "SKIP: case19 (git not available)"
fi

# --- case 20: SKILL.md's documented mode snippet resolves project over global

if command -v git >/dev/null 2>&1; then
  proj=$(new_project)
  git -C "$proj" init -q
  mkdir -p "$proj/.claude/.hygiene" "$proj/sub/dir"
  printf 'propose\n' > "$proj/.claude/.hygiene/mode"
  mkdir -p "$HOME/.claude/document-hygiene"
  printf 'apply\n' > "$HOME/.claude/document-hygiene/mode"

  snippet_file=$(mktemp)
  awk '/MODE_SNIPPET_START/{f=1; next} /MODE_SNIPPET_END/{f=0} f' "$REPO_ROOT/skills/document-hygiene/SKILL.md" \
    | sed -e '/^```/d' > "$snippet_file"

  out=$(cd "$proj/sub/dir" && env -u CLAUDE_PROJECT_DIR -u DOCUMENT_HYGIENE_MODE bash "$snippet_file")
  rm -f "$snippet_file"
  if [ "$out" = "propose" ]; then
    pass "case20: SKILL.md mode snippet, run from a subdirectory, resolves project=propose over global=apply"
  else
    fail "case20: SKILL.md mode snippet, run from a subdirectory, resolves project=propose over global=apply (got: $out)"
  fi
else
  echo "SKIP: case20 (git not available)"
fi

# --- case 21: a plain `mktemp -d` scratch dir (macOS: /var/folders/...;
#     Linux: /tmp/...) is excluded as outside-project scratch, while the
#     identical file placed inside the project IS tracked -------------------
# Regression for the /var/folders/* skip pattern never matching on macOS,
# since CANON_FP is always canonicalized (pwd -P) to /private/var/folders/...

proj=$(new_project)
sid="case21-$$"
outside_dir=$(mktemp -d)
outside_doc="$outside_dir/notes.md"
printf '# Notes\n\nnothing scary\n' > "$outside_doc"
edit_hook "$proj" "$sid" "$outside_doc" >/dev/null
bucket=$(session_bucket_dir "$proj" "$sid")
count_outside=$(cat "$bucket/edit-count" 2>/dev/null || echo 0)

inside_doc="$proj/notes.md"
printf '# Notes\n\nnothing scary\n' > "$inside_doc"
edit_hook "$proj" "$sid" "$inside_doc" >/dev/null
count_after_inside=$(cat "$bucket/edit-count" 2>/dev/null || echo 0)
rm -rf "$outside_dir"

if [ "$count_outside" = "0" ] && [ "$count_after_inside" = "1" ]; then
  pass "case21: plain mktemp -d scratch dir is excluded; the same file inside the project is tracked"
else
  fail "case21: plain mktemp -d scratch dir is excluded; the same file inside the project is tracked (outside=$count_outside after_inside=$count_after_inside)"
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
