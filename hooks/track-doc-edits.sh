#!/usr/bin/env bash
# PostToolUse(Edit|Write|MultiEdit) hook — document-hygiene drift tracker.
# Records edits to long-form docs (.md/.mdx) and scans each for "scar" markers
# (changelog narration, stale-claim flags). Pure bookkeeping; never blocks.
#
# Multi-agent safe:
#   L1  exemption  — skips docs that opt out via an inline `hygiene: ignore`
#                    marker OR a per-project .claude/.hygiene/ignore glob list.
#   L2  attribution — state is namespaced per Claude session_id, so concurrent
#                    agents in the same folder never share counters or get
#                    blamed for each other's edits. Falls back to a "shared"
#                    bucket when no session_id is present (backward compatible).
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
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"

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

# Skip anything under a .claude/ dir (skills, hooks, commands, settings) —
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
    printf '%s/%s\n' "$resolved" "$b"
  else
    printf '%s\n' "$1"
  fi
}

CANON_PROJECT_DIR=$(canon_path "$PROJECT_DIR")
CANON_FP=$(canon_path "$FP")

# A file inside the project directory is always eligible for tracking, even
# if the project itself happens to live under /tmp (a sandbox or throwaway
# checkout). The temp/cache exclusion below only applies to files OUTSIDE the
# project: a fetched-doc cache or agent scratchpad the project pulled from,
# not a file the project owns.
case "$CANON_FP" in
  "$CANON_PROJECT_DIR"|"$CANON_PROJECT_DIR"/*) IN_PROJECT=1 ;;
  *) IN_PROJECT=0 ;;
esac

# Skip OS temp/scratch/cache dirs outside the project — fetched-doc caches
# and agent scratchpads (e.g. /var/folders/.../openai-docs-cache/*.md,
# /private/tmp/claude-*/...) aren't a maintained deliverable and shouldn't
# inflate any project's counter.
if [ "$IN_PROJECT" -eq 0 ]; then
  case "$CANON_FP" in
    /tmp/*|/private/tmp/*|/var/folders/*|*/.cache/*) exit 0 ;;
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
#     glob per line; blank lines and #-comments ignored). Matched against both
#     the basename and the full path.
if [ -f "$IGN" ]; then
  bn=$(basename "$FP")
  while IFS= read -r pat || [ -n "$pat" ]; do
    case "$pat" in ''|\#*) continue ;; esac
    # shellcheck disable=SC2254
    case "$bn" in $pat) exit 0 ;; esac
    # shellcheck disable=SC2254
    case "$FP" in $pat) exit 0 ;; esac
  done < "$IGN"
fi

# --- L2: session-scoped state ------------------------------------------------
SID=$(printf '%s' "$INPUT" | jq -r '.session_id // "shared"' 2>/dev/null)
# Sanitize: session_id becomes a directory name that the Stop hook later
# rm -rf's, so it must never contain path separators or "..". Reject anything
# outside a strict allowlist and fall back to a fixed bucket.
case "$SID" in
  ''|.|..) SID="shared" ;;
  *[!A-Za-z0-9._-]*) SID="shared" ;;
  *..*) SID="shared" ;;
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
if [ -f "$FP" ] && sed '/<!-- *authors/,/-->/d' "$FP" 2>/dev/null \
     | sed -E 's/(TODO|FIXME|XXX|HACK)\([^)]*\)//g' \
     | grep -qEi "$SCAR_REGEX"; then
  grep -qxF "$FP" "$DIR/scarred-docs" 2>/dev/null || echo "$FP" >> "$DIR/scarred-docs"
fi

exit 0
