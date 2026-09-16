#!/usr/bin/env bash
# Stop hook: document-hygiene reminder (per-session).
# Reads ONLY the current Claude session's hygiene bucket, so an agent is
# reminded solely about docs IT edited, never a concurrent agent's work.
# Non-blocking: emits additionalContext only (never decision:block) and resets
# its own bucket after firing, so it cannot recurse.
#
# Runtime state is read from ~/.claude/document-hygiene/state/<project-hash>/,
# matching track-doc-edits.sh (kept out of the repo being edited).

INPUT=$(cat 2>/dev/null)
# Same resolution as track-doc-edits.sh (git toplevel, then cwd), so both
# hooks hash the same project root even when CLAUDE_PROJECT_DIR is unset;
# otherwise the tracker and this hook would read/write different state
# buckets and a reminder would silently vanish.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
PROJHASH=$(printf '%s' "$PROJECT_DIR" | { shasum 2>/dev/null || sha1sum 2>/dev/null; } | cut -c1-16)
[ -z "$PROJHASH" ] && PROJHASH="default"
BASE="${HOME}/.claude/document-hygiene/state/$PROJHASH"
[ -d "$BASE" ] || exit 0

# Coverage is main-agent edits only (see track-doc-edits.sh): a missing or
# malformed session_id cannot be safely bucketed, and there is no shared
# fallback bucket to misattribute a reminder into, so this exits instead.
# Must match the allowlist in track-doc-edits.sh.
SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
case "$SID" in
  ''|.|..) exit 0 ;;
  *[!A-Za-z0-9._-]*) exit 0 ;;
  *..*) exit 0 ;;
esac
DIR="$BASE/sessions/$SID"

# Claude Code sets stop_hook_active=true when a Stop hook already fired for
# this turn and the agent is continuing because of it. Per
# code.claude.com/docs/en/hooks: "Parse the `stop_hook_active` field from the
# JSON input and exit early if it's `true`", a pattern that exists precisely
# to stop a Stop hook from re-triggering itself. Without it, cleanup edits
# the agent makes in response to our own reminder get counted by
# track-doc-edits.sh and fire this same reminder again.
STOP_HOOK_ACTIVE=$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
  case "$DIR" in
    "$BASE/sessions/"?*) rm -rf "$DIR" 2>/dev/null ;;
  esac
  exit 0
fi

# Opportunistic cleanup: prune session buckets untouched for 3+ days so the
# per-session directories can't accumulate forever.
[ -d "$BASE/sessions" ] && find "$BASE/sessions" -mindepth 1 -maxdepth 1 -type d -mtime +3 -exec rm -rf {} + 2>/dev/null

[ -d "$DIR" ] || exit 0

THRESHOLD=5
c=$(cat "$DIR/edit-count" 2>/dev/null || echo 0)

# Re-check exemption against CURRENT file state before reporting: a file
# recorded as touched/scarred at edit time may since have gained a
# hygiene:ignore marker, matched a newly-added ignore glob, or been cleaned
# up. Trusting the historical record instead of current truth is exactly the
# drift this tool exists to prevent, so a report must not do it either.
IGN="$PROJECT_DIR/.claude/.hygiene/ignore"
# Ignore-glob syntax is a subset of gitignore: shell globs matched against
# the basename, the project-relative path, and the absolute path; a pattern
# ending in "/" is a directory prefix (matches anything under it). No
# negation, no `**`. Must match track-doc-edits.sh's matching rules.
is_exempt() {
  f="$1"
  [ -f "$f" ] || return 0
  if head -n 25 "$f" 2>/dev/null | grep -qiE 'hygiene:[[:space:]]*(ignore|skip|collaborative|shared|audit|log)'; then
    return 0
  fi
  if [ -f "$IGN" ]; then
    bn=$(basename "$f")
    case "$f" in
      "$PROJECT_DIR"/*) rel="${f#"$PROJECT_DIR"/}" ;;
      *) rel="$f" ;;
    esac
    while IFS= read -r pat || [ -n "$pat" ]; do
      case "$pat" in ''|\#*) continue ;; esac
      case "$pat" in
        */) test_pat="${pat}*" ;;
        *) test_pat="$pat" ;;
      esac
      # shellcheck disable=SC2254
      case "$bn" in $test_pat) return 0 ;; esac
      # shellcheck disable=SC2254
      case "$rel" in $test_pat) return 0 ;; esac
      # shellcheck disable=SC2254
      case "$f" in $test_pat) return 0 ;; esac
    done < "$IGN"
  fi
  return 1
}

# Keep SCAR_REGEX identical to the copy in hooks/track-doc-edits.sh: both
# hooks must treat the same text as a scar. A justified marker written as
# TODO(<reason>)/FIXME(<reason>)/XXX(<reason>)/HACK(<reason>) is a
# deliberately kept marker, not a scar, so it's stripped before the scan.
SCAR_REGEX='correction|corrected|reversed|verified live|earlier draft|previously (said|claimed)|no longer (true|accurate)|now addressed|decisions logged|⚠|TODO|FIXME|XXX|HACK'

scarred=""
if [ -f "$DIR/scarred-docs" ]; then
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    is_exempt "$f" && continue
    [ -f "$f" ] || continue
    if sed '/<!-- *authors/,/-->/d' "$f" 2>/dev/null \
         | sed -E 's/(TODO|FIXME|XXX|HACK)\([^)]*\)//g' \
         | grep -qEi "$SCAR_REGEX"; then
      scarred="$scarred $f"
    fi
  done < <(sort -u "$DIR/scarred-docs" 2>/dev/null)
  scarred=$(printf '%s' "$scarred" | sed -E 's/^ +//; s/ +$//')
fi

touched=""
touched_arr=()
if [ -f "$DIR/touched-docs" ]; then
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    is_exempt "$f" && continue
    touched="$touched $f"
    touched_arr+=("$f")
  done < <(sort -u "$DIR/touched-docs" 2>/dev/null)
  touched=$(printf '%s' "$touched" | sed -E 's/^ +//; s/ +$//')
fi

# Resolution order, first match wins: env var, project file, global file,
# default "propose". Any value other than the literal string "apply" is
# treated as "propose".
resolve_mode() {
  m=""
  if [ -n "${DOCUMENT_HYGIENE_MODE:-}" ]; then
    m="$DOCUMENT_HYGIENE_MODE"
  elif [ -f "$PROJECT_DIR/.claude/.hygiene/mode" ]; then
    m=$(cat "$PROJECT_DIR/.claude/.hygiene/mode" 2>/dev/null)
  elif [ -f "${HOME}/.claude/document-hygiene/mode" ]; then
    m=$(cat "${HOME}/.claude/document-hygiene/mode" 2>/dev/null)
  fi
  # Trim only leading/trailing whitespace, never interior: stripping ALL
  # whitespace (the old `tr -d '[:space:]'`) would silently turn a corrupted
  # "ap<newline>ply" into "apply" instead of failing closed to "propose".
  m=$(printf '%s' "$m" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  case "$m" in
    apply) printf 'apply' ;;
    *) printf 'propose' ;;
  esac
}
MODE=$(resolve_mode)
if [ "$MODE" = "apply" ]; then
  mode_txt="Mode: apply (edit directly; when nothing needs a human, reply with the single line 'Hygiene pass: ok' and nothing more)."
else
  mode_txt="Mode: propose (list proposed changes and wait for approval; switch with \`echo apply > .claude/.hygiene/mode\`)."
fi

# --- Recovery baseline (apply mode only) -------------------------------------
# Git is the only undo: this tool stores no document content anywhere. For
# each doc that would actually be edited in apply mode, print the exact
# restore command if it's safe to (committed, clean, tracked, a real file);
# otherwise name it as propose-only so the agent never blind-edits something
# it can't hand back. Skipped entirely in propose mode: nothing gets edited.
recovery_line() {
  f="$1"
  not_safe="${f}: not committed and clean, propose only"
  if [ "$GIT_OK" -ne 1 ]; then
    printf '%s' "$not_safe"; return
  fi
  if [ -L "$f" ]; then
    printf '%s' "$not_safe"; return
  fi
  # Canonicalize the file's directory before any git call: a temp dir (e.g.
  # macOS /var/folders/...) and its own `git rev-parse --show-toplevel`
  # (.../private/var/folders/...) can disagree on a raw, unresolved path,
  # which would misreport every doc as unsafe.
  fdir=$(cd "$(dirname "$f")" 2>/dev/null && pwd -P)
  if [ -z "$fdir" ]; then
    printf '%s' "$not_safe"; return
  fi
  fabs="$fdir/$(basename "$f")"
  root=$(git -C "$fdir" rev-parse --show-toplevel 2>/dev/null)
  if [ -z "$root" ]; then
    printf '%s' "$not_safe"; return
  fi
  if ! git -C "$fdir" ls-files --error-unmatch -- "$fabs" >/dev/null 2>&1; then
    printf '%s' "$not_safe"; return
  fi
  if [ -n "$(git -C "$fdir" status --porcelain -- "$fabs" 2>/dev/null)" ]; then
    printf '%s' "$not_safe"; return
  fi
  sha=$(git -C "$root" rev-parse HEAD 2>/dev/null)
  rel=$(git -C "$fdir" ls-files --full-name -- "$fabs" 2>/dev/null | head -n1)
  if [ -z "$sha" ] || [ -z "$rel" ]; then
    printf '%s' "$not_safe"; return
  fi
  printf 'restore: git -C %s restore --source=%s --worktree -- %s' "$root" "$sha" "$rel"
}

# Emit only when there is something left to act on. The raw edit count is
# historical and can outlive the docs it counted (all of them since gained a
# 'hygiene: ignore' marker, or were removed), so emitting on count alone
# produces a reminder naming zero targets. Gate on the filtered `touched`
# list instead: it must be non-empty, and either the threshold was hit or a
# scar was found among what's left.
if [ -n "$touched" ] && { [ "$c" -ge "$THRESHOLD" ] || [ -n "$scarred" ]; }; then
  msg="Document-hygiene check due: ${c} doc edit(s) since the last pass (this session only)."
  [ -n "$scarred" ] && msg="${msg} Drift/changelog markers found in: ${scarred}."
  msg="${msg} Touched docs: ${touched}."
  msg="${msg} These are only docs YOU edited this session. Skip any doc you did not author this session or that carries a 'hygiene: ignore' marker (another agent may own it). Otherwise run the document-hygiene skill on the rest: fact-check every claim against current evidence, delete stale/contradicted statements and changelog narration, so each doc reads as a clean current version. ${mode_txt}"

  # Only computed when a reminder is actually about to fire, and only in
  # apply mode (in propose mode nothing is edited, so there's nothing to
  # recover a baseline for).
  if [ "$MODE" = "apply" ]; then
    GIT_OK=0
    command -v git >/dev/null 2>&1 && GIT_OK=1
    recovery_txt=""
    for f in "${touched_arr[@]}"; do
      recovery_txt="${recovery_txt}
$(recovery_line "$f")"
    done
    msg="${msg}${recovery_txt}"
  fi

  # Reset this session's cycle BEFORE emitting (prevents any Stop-hook recursion).
  # Defense in depth: never rm -rf outside the sessions root, even if SID
  # sanitization is ever bypassed.
  case "$DIR" in
    "$BASE/sessions/"?*) rm -rf "$DIR" 2>/dev/null ;;
  esac

  jq -cn --arg ctx "$msg" '{hookSpecificOutput:{hookEventName:"Stop",additionalContext:$ctx}}' 2>/dev/null
elif [ -z "$touched" ]; then
  # Every touched doc got filtered out (all now exempt, or all gone): there
  # is nothing left to name in a reminder, so reset the stale bucket
  # silently instead of counting toward a future report with no targets.
  case "$DIR" in
    "$BASE/sessions/"?*) rm -rf "$DIR" 2>/dev/null ;;
  esac
fi
# Else: below threshold, no scars, and at least one real target remains.
# Leave the bucket in place so edits keep accumulating toward the threshold
# across future Stop events in this session.

exit 0
