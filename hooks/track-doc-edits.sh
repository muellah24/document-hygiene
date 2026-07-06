#!/usr/bin/env bash
# PostToolUse(Edit|Write) hook — document-hygiene drift tracker.
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
# Strip the intentional `<!-- authors ... -->` metadata block first, so authorship
# descriptions (e.g. "fact-checked", "corrected numbers") never trip scar detection.
if [ -f "$FP" ] && sed '/<!-- *authors/,/-->/d' "$FP" 2>/dev/null | grep -qEi 'correction|corrected|reversed|verified live|earlier draft|previously (said|claimed)|no longer (true|accurate)|now addressed|decisions logged|⚠|TODO|FIXME|XXX|HACK'; then
  grep -qxF "$FP" "$DIR/scarred-docs" 2>/dev/null || echo "$FP" >> "$DIR/scarred-docs"
fi

exit 0
