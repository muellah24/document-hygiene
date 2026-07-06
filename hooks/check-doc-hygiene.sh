#!/usr/bin/env bash
# Stop hook — document-hygiene reminder (per-session).
# Reads ONLY the current Claude session's hygiene bucket, so an agent is
# reminded solely about docs IT edited — never a concurrent agent's work.
# Non-blocking: emits additionalContext only (never decision:block) and resets
# its own bucket after firing, so it cannot recurse.
#
# Runtime state is read from ~/.claude/document-hygiene/state/<project-hash>/,
# matching track-doc-edits.sh (kept out of the repo being edited).

INPUT=$(cat 2>/dev/null)
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
PROJHASH=$(printf '%s' "$PROJECT_DIR" | { shasum 2>/dev/null || sha1sum 2>/dev/null; } | cut -c1-16)
[ -z "$PROJHASH" ] && PROJHASH="default"
BASE="${HOME}/.claude/document-hygiene/state/$PROJHASH"
[ -d "$BASE" ] || exit 0

SID=$(printf '%s' "$INPUT" | jq -r '.session_id // "shared"' 2>/dev/null)
# Sanitize: SID is used to build a path that gets rm -rf'd below. Reject path
# separators and traversal; fall back to the fixed bucket. Must match the
# allowlist in track-doc-edits.sh.
case "$SID" in
  ''|.|..) SID="shared" ;;
  *[!A-Za-z0-9._-]*) SID="shared" ;;
  *..*) SID="shared" ;;
esac
DIR="$BASE/sessions/$SID"

# Opportunistic cleanup: prune session buckets untouched for 3+ days so the
# per-session directories can't accumulate forever.
[ -d "$BASE/sessions" ] && find "$BASE/sessions" -mindepth 1 -maxdepth 1 -type d -mtime +3 -exec rm -rf {} + 2>/dev/null

[ -d "$DIR" ] || exit 0

THRESHOLD=5
c=$(cat "$DIR/edit-count" 2>/dev/null || echo 0)

scarred=""
[ -f "$DIR/scarred-docs" ] && scarred=$(sort -u "$DIR/scarred-docs" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')
touched=""
[ -f "$DIR/touched-docs" ] && touched=$(sort -u "$DIR/touched-docs" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')

if [ "$c" -ge "$THRESHOLD" ] || [ -n "$scarred" ]; then
  msg="Document-hygiene check due: ${c} doc edit(s) since the last pass (this session only)."
  [ -n "$scarred" ] && msg="${msg} Drift/changelog markers found in: ${scarred}."
  [ -n "$touched" ] && msg="${msg} Touched docs: ${touched}."
  msg="${msg} These are only docs YOU edited this session. Skip any doc you did not author this session or that carries a 'hygiene: ignore' marker (another agent may own it). Otherwise run the document-hygiene skill on the rest: fact-check every claim against current evidence, delete stale/contradicted statements and changelog narration, and ensure each doc reads as a clean current version."

  # Reset this session's cycle BEFORE emitting (prevents any Stop-hook recursion).
  # Defense in depth: never rm -rf outside the sessions root, even if SID
  # sanitization is ever bypassed.
  case "$DIR" in
    "$BASE/sessions/"?*) rm -rf "$DIR" 2>/dev/null ;;
  esac

  jq -cn --arg ctx "$msg" '{hookSpecificOutput:{hookEventName:"Stop",additionalContext:$ctx}}' 2>/dev/null
fi

exit 0
