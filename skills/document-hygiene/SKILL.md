---
name: document-hygiene
description: >-
  Use when maintaining a long-lived document, plan, spec, report, README, or
  any artifact edited across multiple turns or days: to fact-check it against
  current evidence, remove stale or contradicted claims, and strip
  accumulated changelog/correction narration so it reads as a clean current
  version. Trigger on "clean up this doc", "is this still accurate", "remove
  the correction scars", a doc edited many times, after
  reversing/correcting any earlier claim, when the automatic Stop-hook
  hygiene reminder fires, or when asked "is this project doc still
  current", "check the project description against its issues", or
  "reconcile the Linear/Jira project doc".
---

<!-- hygiene: ignore --><!-- this skill documents the hygiene tool's own trigger vocabulary (corrected/reversed/TODO/etc.) as subject matter, not as drift in the doc itself -->

# Document Hygiene

Long-lived artifacts drift: each turn patches the immediate ask and leaves old text in place, so stale claims, self-contradictions, and changelog scars accumulate. Patching is not reconciling. This skill reconciles an artifact back to a single, current, clean truth.

It applies to any project doc kept alive across turns or days, not just code: a launch plan, a product spec, a status report, a project README. If you run a project with a goal and keep a living document about it, this is for you, whether you're a product manager, project manager, product owner, scrum master, founder, or a vibe coder keeping a plan file next to your code.

## When to run
- The Stop-hook reminder fired (5+ doc edits, or drift markers detected).
- Before presenting any maintained artifact as "done" or "updated".
- Immediately after you reverse or correct a claim: drift clusters, so the same stale claim is usually echoed elsewhere in the doc.
- A document has been edited many times across a long session or multiple days.

## Step 0: Preflight

Run this before touching any text.

**(a) Determine the mode.** Resolution order, first match wins:
1. Environment variable `DOCUMENT_HYGIENE_MODE`.
2. `<project>/.claude/.hygiene/mode` (project-level file, literal contents `propose` or `apply`).
3. `~/.claude/document-hygiene/mode` (global file, same format).
4. Default: `propose`.

Once a source is selected (the env var is set, or the project file exists, or the global file exists, in that order), an empty or malformed value there resolves to `propose` directly: it never falls through to a lower-priority source. Resolve the project root the same way the hooks do, so running this from a subdirectory never disagrees with them:

<!-- MODE_SNIPPET_START -->
```bash
ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
# Test presence, not non-emptiness: a SET-but-empty env var still selects this source.
if [ "${DOCUMENT_HYGIENE_MODE+x}" = x ]; then
  RAW="$DOCUMENT_HYGIENE_MODE"
elif [ -f "$ROOT/.claude/.hygiene/mode" ]; then
  RAW=$(cat "$ROOT/.claude/.hygiene/mode" 2>/dev/null)
elif [ -f "$HOME/.claude/document-hygiene/mode" ]; then
  RAW=$(cat "$HOME/.claude/document-hygiene/mode" 2>/dev/null)
else
  RAW=""
fi
# Trim only leading/trailing whitespace, never interior: a corrupted
# "ap<newline>ply" must not silently become "apply".
TRIMMED=$(printf '%s' "$RAW" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
case "$TRIMMED" in
  apply) MODE=apply ;;
  *) MODE=propose ;;
esac
printf '%s\n' "$MODE"
```
<!-- MODE_SNIPPET_END -->

- **propose** (default): re-read and re-verify as usual, but do not edit the doc. Present a compact list of proposed changes (for each: current text, proposed text, and the evidence behind the change) and wait for the user to accept before applying anything.
- **apply**: edit directly. Afterwards reply with the single line `Hygiene pass: ok` unless something needs the user (see step 9).

**(b) Skip exempt docs.** Skip any doc carrying a `hygiene: ignore`-style marker in its first 25 lines, or matching a glob in `<project>/.claude/.hygiene/ignore`. These are opted out deliberately (shared docs, audit logs, specs where "corrected" is the subject matter).

**(c) Scope to what you own.** Automatic reconciliation (apply mode) is allowed only for docs you created in this session. For any pre-existing doc, apply-mode edits happen only when the user explicitly asked you, by name, to clean that doc; otherwise propose rather than apply, regardless of mode: another agent or the user may own that doc's current state.

**Bounded edits.** Whether proposing or applying:
- Re-read the doc immediately before editing it; do not trust an earlier read from this session.
- Make localized edits with the exact expected old text (the Edit tool's `old_string`) so a changed preimage fails the edit instead of silently overwriting another agent's work. Never replace a whole pre-existing file with `Write`.
- Every edit must be backed by a specific piece of evidence gathered in this pass. When the evidence is ambiguous, leave the text alone and propose instead of guessing.
- Before declaring done, review the diff (`git diff -- <doc>` when the doc is in a git work tree) and confirm no section heading disappeared unintentionally.
- The Stop hook does not run on user interruption, so a pass must never leave a doc half-edited across turns: finish or revert each doc within the same turn.

**(d) A vocabulary match is a lead, not a verdict.** Finding "corrected", "TODO", or a date in a doc is a review candidate, never proof the text should be deleted. Remove the narration about the edit; keep the decision itself, its rationale, research observations, quotes, and creative intent. "We corrected the launch date to March 3" narrates an edit, so strip it. "We're launching March 3 because retail partners need six weeks lead time" is a decision with its rationale, so keep it.

**(e) Recovery baseline (apply mode only).** This tool stores no document content anywhere, not even temporarily: git is the only undo. Before editing a doc in apply mode, confirm all three with shell commands you run yourself:
1. The doc is inside a git work tree: `git -C "$(dirname "$f")" rev-parse --show-toplevel`.
2. It is a tracked regular file, not a symlink: `git ls-files --error-unmatch -- "$f"` and `test -L "$f"` (must fail, i.e. not a symlink).
3. It has no staged or unstaged changes for that path: `git status --porcelain -- "$f"` prints nothing.

If all three hold, record the commit (`git rev-parse HEAD`) and the repo-relative path, and keep the exact restore command ready, in this form, shell-quoted (e.g. with bash's `printf '%q'`) so it can be pasted and run as-is even when a path contains spaces:
```
git -C <root> restore --source=<sha> --worktree -- <relative-path>
```
Do not print the command to the user up front. Before the first edit, tell them in three words that the undo exists: `Undo ready (git).` Print the full command only if the pass goes wrong (an edit you could not complete or verify) or if the user asks how to undo. When the pass was triggered by the Stop-hook reminder in apply mode, the reminder already carries this command per doc, already quoted; reuse it rather than recomputing.

If any check fails, handle that doc in propose mode even though the session mode is apply, and say so in one line, naming the specific reason (not in a git repository, never committed, has uncommitted changes, is a symlink, or git not installed). When the reason is "not in a git repository", say so and OFFER to initialize git for the folder (one time: `git init`, add the docs, commit); never run `git init` unasked, because creating a `.git` directory in someone's folder (Dropbox, Drive, a shared folder) is a visible change they must approve. Never auto-commit, never stash (`git stash create` writes objects; it is not storage-free and is not a durable recovery point).

## Living documents in project-management tools

Everything above assumes the document is a file you can re-read and edit with Edit/Write. A project's "current state" doc can also live inside a project-management tool instead: a Linear project document, a Jira or Confluence page, a Notion database entry, a GitHub Projects readme. The doc doesn't change shape, but two things do: what "current evidence" means (the issue graph, not a second file to fetch), and how a fix reaches the doc (a comment, never a direct edit).

**Evidence.** For a PM doc, current evidence is the issue graph: issue statuses and completion dates, issue relations (blocks/blocked-by, parent/child), linked pull-request state, and sibling documents in the same project. Re-verifying a claim (step 2 below) means checking it against the issue graph, the same way it means re-running a query or re-fetching a page for a code or plan doc.

**Opt-in marker.** A PM doc is checked only when it carries a `hygiene: watch` marker in its first 25 lines (the positive mirror of `hygiene: ignore`), or on explicit request. Most PM editors strip HTML comments, so this marker is a plain visible line of text, not a comment: `hygiene: watch`. A doc without the marker is left alone unless the user asks by name.

**The trigger is a data contract, not a schedule.** Four deterministic rules over fields every PM tool exposes (the doc's text and updatedAt; each issue's id, state, stateType, createdAt, updatedAt) decide whether a reconciliation pass is due at all:

| Rule | Fires when |
|---|---|
| T1 (status mismatch) | An issue ID referenced in the doc text whose current stateType disagrees with the status wording on the same line as the ID (unstarted / started / completed word classes). |
| T1b (weaker: silent drift) | A referenced issue updated after the doc, now started or completed, with no status word at all on any line that mentions it. |
| T2 (volume) | At least N issues (default 5) updated after the doc's own updatedAt. |
| T3 (age) | The doc is older than X days (default 7) while the project is still active. |
| T4 (unreferenced new work) | Issues created after the doc's updatedAt whose ID never appears in the doc text. |

`bin/check-staleness` implements this evaluator, tool-independently: it reads one JSON object (the doc's text and updatedAt, plus an issues array) on stdin and reports which rules fired and why. A per-tool recipe only has to produce that JSON; it never re-implements the rules. (Installed, this script lives at `~/.claude/bin/check-staleness`; every other mention of `bin/check-staleness` in this skill and its references means that installed copy, or the repo path of the same name when working inside this repo.) See `references/linear.md`, `references/jira.md`, and `references/generic.md` for the recipes, and the script's own header comment for the exact input and output shape.

**Checklist**, once the trigger fires (or on explicit request): status words in the doc against each referenced issue's real status; counts and lists in the doc against the ticket that defines them; a "not yet ticketed" or "planned, no ticket" list against issues that already exist; decisions recorded in the doc against later run reports or completed-ticket outcomes; and names (models, columns, classes, tools) against whatever the most recently completed ticket actually shipped.

**Propose only, delivered as a comment.** Apply mode does not exist for a PM doc: there is no git undo there, so every PM-doc reconciliation runs in propose mode regardless of the session's configured mode. The result is delivered as a comment on the document or project (every PM tool has comments), never written into the doc itself.

**Scheduling is offered, never created unasked.** Wiring the check to a clock or an event (a scheduled task, a cron job, a webhook, an agent mention) is host-specific and documented per tool in `references/`, not built into this skill. The first time this skill runs a PM-doc check manually, offer to set up a recurring check on whichever mechanism the host supports, and wait for a yes before creating anything.

## Procedure

1. **Re-read the whole artifact fresh.** Do not trust your memory of what it says: open it and read it end to end. Drift hides in the sections you didn't touch this turn.

2. **Extract every factual claim and re-verify it against current evidence.** For each load-bearing statement (numbers, tool/system behavior, "X causes Y", "we do/don't have Z"): re-run the query, re-fetch the page, re-check the live state. **Strong confidence in an older claim is the cue to verify, not to skip**: a stale prior feels identical to a checked fact. (Pairs with the global "Verify Before Asserting" rule.)

   What drifts in project docs specifically, check each:
   - Owners and roles ("Priya owns onboarding" after Priya left the team).
   - Dates and deadlines.
   - Scope: what's in, what's out.
   - Phase and dependency status ("blocked on X" after X shipped).
   - Success metrics and targets.
   - Decisions and their current state (reversed but still stated as active).
   - Counts and budgets.
   - Names of tools, files, and links.

   Example (PM-flavored): a launch plan still lists "blocked on the payments API migration" two weeks after that migration shipped, so the reader plans around a dependency that no longer exists. Example (coding): a README's install step calls `setup.sh`; the script was renamed to `bootstrap.sh` months ago and nobody updated the doc.

   **Step 2b (PM-tool docs only).** When the artifact is a document living inside a project-management tool rather than a file, "current evidence" is the issue graph, not a second file to fetch: for each status word in the doc, look up the referenced issue's real state; for each count or list, check it against the ticket that defines it; for each "not yet ticketed" mention, check whether a ticket now exists; for each decision, check it against later run reports; for each named model, column, or tool, check it against the latest completed ticket. See "Living documents in project-management tools" above for the trigger rules and delivery (propose-only, posted as a comment, never edited into the doc).

3. **Reconcile contradictions.** If two parts of the doc disagree, find ground truth and fix *both*: don't leave the reader to guess which is current.

4. **Strip changelog / correction narration.** Remove edit-history scar tissue: "corrected", "reversed", "verified live on <date>", "an earlier draft claimed…", "⚠ correction", "now addressed", "(reversed 2026-..)", ✓-decision logs, and dated parentheticals that narrate *what changed*. The document states the **current truth**, not the story of its edits. If edit history matters, it belongs in version control or a separate CHANGELOG, not inline.

5. **Resolve stale markers.** Delete done TODO/FIXME/XXX; keep only ones still real, with a reason. A marker written as `TODO(<reason>)` (the marker immediately followed by a parenthesized reason, e.g. `TODO(keep until v2 ships)`) is a deliberately kept marker, not a scar; leave it. A bare `TODO`/`FIXME`/`XXX`/`HACK` with no reason attached is a scar candidate: resolve it or give it one.

6. **Check structural integrity after edits.** Cross-references, section numbers/letters, link targets, and tier/item IDs still line up. Renumbering drift is common after insertions/deletions.

7. **Deterministic scar scan.** This is a review list, not an auto-delete list: a hit is a candidate to look at, never by itself proof the text is wrong. Legitimate matches stay in place: a frontmatter title, a code sample (`reversed(values)`), a quotation, a research or decision sentence ("the reversed order improved accuracy"), or the `<!-- authors ... -->` block itself. Strip the authors block and justified markers first, then scan:
   ```
   sed -E -e '/<!-- *authors/,/-->/d' -e 's/(TODO|FIXME|XXX|HACK)\([^)]*\)//g' <file> | grep -nEi 'correction|corrected|reversed|verified live|earlier draft|previously (said|claimed)|no longer (true|accurate)|now addressed|decisions logged|⚠|TODO|FIXME|XXX|HACK'
   ```
   "Done" means every remaining hit has been looked at and judged legitimate (kept on purpose) or fixed, not that the grep returns zero matches.

8. **Fresh-reader test.** Would someone with zero session history read this as one coherent current document: no contradictions, no "wait, which claim is right?", no visible edit scars? If not, fix what they'd trip on.

9. **Report according to mode.** In **apply** mode: housekeeping is your job, not a status update. When nothing needs the user, reply with one line, `Hygiene pass: ok`, and nothing more: no list of what you pruned, re-verified or renamed, no restating of the project status. Write more only when something changes what the user does (a claim you fixed that contradicts advice they already acted on, a decision only they can make, a setting they need to change) or when something out of the ordinary happened in the pass (a doc you could not reconcile, a restore you had to run, a contradiction you could not resolve). Then lead with that item, not with the pass. In **propose** mode: present the compact change list from Step 0(a) and stop; do not apply anything until the user accepts.

## Anti-patterns
- Trusting your own summary of the doc instead of re-reading it.
- "Fixing" only the section the user pointed at, leaving the same stale claim elsewhere.
- Replacing a wrong claim with a *new* unverified claim (verify the replacement too).
- Turning the doc into a changelog ("was X, now Y, corrected on Z"): that IS the scar.
