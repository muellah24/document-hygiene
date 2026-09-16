#!/usr/bin/env bash
# PostToolUse(Edit|Write|MultiEdit) hook: document-hygiene drift tracker.
# Records edits to long-form docs (.md/.mdx) and scans each for "scar" markers
# (changelog narration, stale-claim flags). Pure bookkeeping; never blocks.
# Coverage is main-agent edits only: a subagent tool call carries its own
# `agent_id` (code.claude.com/docs/en/hooks) and is skipped rather than
# credited to the parent session's bucket.
#
# Multi-agent safe:
#   L1  exemption  : skips docs that opt out via an inline `hygiene: ignore`
#                    marker OR a per-project .claude/.hygiene/ignore glob list.
#   L2  attribution: state is namespaced per Claude session_id, so concurrent
#                    agents in the same folder never share counters or get
#                    blamed for each other's edits. A subagent call (agent_id
#                    present) or a missing/malformed session_id is not
#                    tracked at all: there is no shared fallback bucket left
#                    to misattribute edits into.
#
# A file inside the project directory is always tracked, even if the project
# itself lives under /tmp or /var/folders (a sandbox or throwaway checkout).
# The temp/cache exclusion only skips files OUTSIDE the project that happen
# to sit under a temp/cache path.
#
# Storage split:
#   - User config  (.claude/.hygiene/ignore) stays project-local & committable.
#   - Runtime state lives OUTSIDE the repo under
#     ~/.claude/document-hygiene/state/<project-hash>/ so ordinary markdown
#     edits never litter project trees with untracked bookkeeping files.

INPUT=$(cat 2>/dev/null)

# If jq isn't on the PATH hooks run with, every jq call below returns empty
# and FP would look "unset", silently skipping every edit with nobody told.
# Fail loud instead: stop here (nothing to track without jq), and clear the
# outage marker on recovery so check-doc-hygiene.sh's one-time warning
# re-arms if jq later goes missing again.
JQ_MISSING_MARKER="$HOME/.claude/document-hygiene/jq-missing"
if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi
rmdir "$JQ_MISSING_MARKER" 2>/dev/null

# Same resolution as check-doc-hygiene.sh (git toplevel, then cwd), so both
# hooks hash the same project root even when CLAUDE_PROJECT_DIR is unset;
# otherwise the tracker and the Stop hook would write/read different state
# buckets and reminders would silently vanish.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

# User-authored ignore globs stay project-local (intentional, committable).
IGN="$PROJECT_DIR/.claude/.hygiene/ignore"

# Runtime state is keyed by a hash of the project dir and kept under $HOME so it
# never pollutes the repo being edited.
PROJHASH=$(printf '%s' "$PROJECT_DIR" | { shasum 2>/dev/null || sha1sum 2>/dev/null; } | cut -c1-16)
[ -z "$PROJHASH" ] && PROJHASH="default"
BASE="${HOME}/.claude/document-hygiene/state/$PROJHASH"

# Which file was edited?
FP=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$FP" ] && exit 0

# Skip anything under a .claude/ dir (skills, hooks, commands, settings):
# config, not drift-prone deliverables.
case "$FP" in
  */.claude/*) exit 0 ;;
esac

# Canonicalize a path's directory (resolves symlinks, ".."), falling back to
# the raw string when the directory can't be resolved (e.g. it doesn't exist
# yet). macOS has no `realpath` by default, so this uses `cd && pwd -P`
# instead. Run in a subshell so it never changes the script's own cwd.
canon_path() {
  d=$(dirname "$1")
  b=$(basename "$1")
  resolved=$(cd "$d" 2>/dev/null && pwd -P)
  if [ -n "$resolved" ]; then
    case "$resolved" in
      /) printf '%s%s\n' "$resolved" "$b" ;;  # avoid a "//basename" artifact
      *) printf '%s/%s\n' "$resolved" "$b" ;;
    esac
  else
    printf '%s\n' "$1"
  fi
}

# The project dir itself can be a symlink (e.g. PROJECT_DIR=/tmp on macOS,
# where /tmp -> /private/tmp): canonicalize it directly with cd+pwd -P
# instead of resolving only its parent and re-appending its own basename
# (canon_path's approach, needed for the FILE since it may not exist yet).
# The parent+basename approach applied to the project dir itself would leave
# a symlinked project root unresolved and mismatch every file canonicalized
# underneath it.
CANON_PROJECT_DIR=$(cd "$PROJECT_DIR" 2>/dev/null && pwd -P)
CANON_FP=$(canon_path "$FP")

# A file inside the project directory is always eligible for tracking, even
# if the project itself happens to live under /tmp (a sandbox or throwaway
# checkout). The temp/cache exclusion below only applies to files OUTSIDE the
# project: a fetched-doc cache or agent scratchpad the project pulled from,
# not a file the project owns.
if [ -z "$CANON_PROJECT_DIR" ] || [ -z "$CANON_FP" ]; then
  # Canonicalization failed (e.g. the project dir doesn't exist yet): treat
  # the file as in-project rather than risk silently dropping it as scratch.
  IN_PROJECT=1
else
  case "$CANON_FP" in
    "$CANON_PROJECT_DIR"|"$CANON_PROJECT_DIR"/*) IN_PROJECT=1 ;;
    *) IN_PROJECT=0 ;;
  esac
fi

# Skip OS temp/scratch/cache dirs outside the project: fetched-doc caches
# and agent scratchpads (e.g. /var/folders/.../openai-docs-cache/*.md,
# /private/tmp/claude-*/...) aren't a maintained deliverable and shouldn't
# inflate any project's counter. CANON_FP is always the canonicalized
# (pwd -P) form, and on macOS /var and /tmp are themselves symlinks to
# /private/var and /private/tmp, so both the raw and /private-resolved
# forms are listed; Linux has a real /tmp and no /private prefix, where
# the plain entries already match.
if [ "$IN_PROJECT" -eq 0 ]; then
  case "$CANON_FP" in
    /tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*|*/.cache/*) exit 0 ;;
  esac
fi

# Only track long-form documents (where drift accumulates).
case "$FP" in
  *.md|*.mdx|*.markdown) ;;
  *) exit 0 ;;
esac

# --- L1: declarative exemption -----------------------------------------------
# (a) Inline opt-out marker in the first 25 lines, e.g. `<!-- hygiene: ignore -->`
#     (also accepts skip / collaborative / shared / audit / log).
if [ -f "$FP" ] && head -n 25 "$FP" 2>/dev/null \
     | grep -qiE 'hygiene:[[:space:]]*(ignore|skip|collaborative|shared|audit|log)'; then
  exit 0
fi
# (b) Per-project ignore globs in .claude/.hygiene/ignore (one gitignore-style
#     glob per line; blank lines and #-comments ignored). A subset of
#     gitignore syntax: shell globs matched against the basename, the
#     project-relative path, and the absolute path; a pattern ending in "/"
#     is a directory prefix (matches anything under it). No negation, no `**`.
if [ "$IN_PROJECT" -eq 1 ] && [ -n "$CANON_PROJECT_DIR" ] && [ -n "$CANON_FP" ]; then
  case "$CANON_PROJECT_DIR" in
    /) REL_FP="${CANON_FP#/}" ;;
    *) REL_FP="${CANON_FP#"$CANON_PROJECT_DIR"/}" ;;
  esac
else
  REL_FP="$FP"
fi
if [ -f "$IGN" ]; then
  bn=$(basename "$FP")
  while IFS= read -r pat || [ -n "$pat" ]; do
    case "$pat" in ''|\#*) continue ;; esac
    case "$pat" in
      */) test_pat="${pat}*" ;;
      *) test_pat="$pat" ;;
    esac
    # shellcheck disable=SC2254
    case "$bn" in $test_pat) exit 0 ;; esac
    # shellcheck disable=SC2254
    case "$REL_FP" in $test_pat) exit 0 ;; esac
    # shellcheck disable=SC2254
    case "$FP" in $test_pat) exit 0 ;; esac
  done < "$IGN"
fi

# --- L2: session-scoped state ------------------------------------------------
# Subagent tool calls carry their own agent_id alongside the parent's
# session_id. Per code.claude.com/docs/en/hooks: "agent_id: Unique
# identifier for the subagent. Present only when the hook fires inside a
# subagent call. Use this to distinguish subagent hook calls from
# main-thread calls." Skip these rather than crediting them to the parent
# session's bucket: coverage is main-agent edits only.
AGENT_ID=$(printf '%s' "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null)
[ -n "$AGENT_ID" ] && exit 0

SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
# Sanitize: session_id becomes a directory name that the Stop hook later
# rm -rf's, so it must never contain path separators or "..". A missing or
# malformed session_id is not tracked at all: there is no shared fallback
# bucket to misattribute the edit into.
case "$SID" in
  ''|.|..) exit 0 ;;
  *[!A-Za-z0-9._-]*) exit 0 ;;
  *..*) exit 0 ;;
esac
DIR="$BASE/sessions/$SID"
mkdir -p "$DIR" 2>/dev/null

# Count this edit.
c=$(cat "$DIR/edit-count" 2>/dev/null || echo 0)
echo $((c + 1)) > "$DIR/edit-count"

# Remember the touched doc (deduped).
grep -qxF "$FP" "$DIR/touched-docs" 2>/dev/null || echo "$FP" >> "$DIR/touched-docs"

# Flag drift / changelog "scars" present in the current file.
# Keep SCAR_REGEX identical to the copy in hooks/check-doc-hygiene.sh: both
# hooks must treat the same text as a scar.
SCAR_REGEX='correction|corrected|reversed|verified live|earlier draft|previously (said|claimed)|no longer (true|accurate)|now addressed|decisions logged|⚠|TODO|FIXME|XXX|HACK'
# A justified marker written as TODO(<reason>)/FIXME(<reason>)/XXX(<reason>)/
# HACK(<reason>) is a deliberately kept marker, not a scar, so strip those
# before scanning: only a BARE marker (no parenthesized reason) should count.
if [ -f "$FP" ] && sed -E -e '/<!-- *authors/,/-->/d' -e 's/(TODO|FIXME|XXX|HACK)\([^)]*\)//g' "$FP" 2>/dev/null \
     | grep -qEi "$SCAR_REGEX"; then
  grep -qxF "$FP" "$DIR/scarred-docs" 2>/dev/null || echo "$FP" >> "$DIR/scarred-docs"
fi

exit 0
