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

INPUT=$(cat 2>/dev/null)
BASE="${CLAUDE_PROJECT_DIR:-$PWD}/.claude/.hygiene"

# Which file was edited?
FP=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$FP" ] && exit 0

# Skip anything under a .claude/ dir (skills, hooks, commands, settings, hygiene
# state) — config, not drift-prone deliverables.
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
IGN="$BASE/ignore"
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
[ -z "$SID" ] && SID="shared"
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
