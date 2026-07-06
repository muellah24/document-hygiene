#!/usr/bin/env bash
# Stop hook — document-hygiene reminder (per-session).
# Reads ONLY the current Claude session's hygiene bucket, so an agent is
# reminded solely about docs IT edited — never a concurrent agent's work.
# Non-blocking: emits additionalContext only (never decision:block) and resets
# its own bucket after firing, so it cannot recurse.

INPUT=$(cat 2>/dev/null)
BASE="${CLAUDE_PROJECT_DIR:-$PWD}/.claude/.hygiene"
[ -d "$BASE" ] || exit 0

SID=$(printf '%s' "$INPUT" | jq -r '.session_id // "shared"' 2>/dev/null)
[ -z "$SID" ] && SID="shared"
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
  rm -rf "$DIR" 2>/dev/null

  jq -cn --arg ctx "$msg" '{hookSpecificOutput:{hookEventName:"Stop",additionalContext:$ctx}}' 2>/dev/null
fi

exit 0
