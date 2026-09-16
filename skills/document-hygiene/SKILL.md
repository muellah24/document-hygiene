---
name: document-hygiene
description: Use when maintaining a long-lived document, plan, spec, report, README, or any artifact edited across multiple turns or days — to fact-check it against current evidence, remove stale or contradicted claims, and strip accumulated changelog/correction narration so it reads as a clean current version. Trigger on "clean up this doc", "is this still accurate", "remove the correction scars", a doc edited many times, after reversing/correcting any earlier claim, or when the automatic Stop-hook hygiene reminder fires.
---

<!-- hygiene: ignore --><!-- this skill documents the hygiene tool's own trigger vocabulary (corrected/reversed/TODO/etc.) as subject matter, not as drift in the doc itself -->

# Document Hygiene

Long-lived artifacts drift: each turn patches the immediate ask and leaves old text in place, so stale claims, self-contradictions, and changelog scars accumulate. Patching is not reconciling. This skill reconciles an artifact back to a single, current, clean truth.

It applies to any project doc kept alive across turns or days, not just code: a launch plan, a product spec, a status report, a project README. If you run a project with a goal and keep a living document about it, this is for you, whether you're a product manager, project manager, product owner, scrum master, founder, or a vibe coder keeping a plan file next to your code.

## When to run
- The Stop-hook reminder fired (N+ doc edits, or drift markers detected).
- Before presenting any maintained artifact as "done" or "updated".
- Immediately after you reverse or correct a claim — drift clusters, so the same stale claim is usually echoed elsewhere in the doc.
- A document has been edited many times across a long session or multiple days.

## Step 0: Preflight

Run this before touching any text.

**(a) Determine the mode.** Resolution order, first match wins:
1. Environment variable `DOCUMENT_HYGIENE_MODE`.
2. `<project>/.claude/.hygiene/mode` (project-level file, literal contents `propose` or `apply`).
3. `~/.claude/document-hygiene/mode` (global file, same format).
4. Default: `propose`.

Check it with a shell command, e.g.:
```
echo "${DOCUMENT_HYGIENE_MODE:-$(cat .claude/.hygiene/mode 2>/dev/null || cat ~/.claude/document-hygiene/mode 2>/dev/null || echo propose)}"
```
- **propose** (default): re-read and re-verify as usual, but do not edit the doc. Present a compact list of proposed changes (for each: current text, proposed text, and the evidence behind the change) and wait for the user to accept before applying anything.
- **apply**: edit directly. Stay silent afterward unless something changes what the user must do (see step 9).

**(b) Skip exempt docs.** Skip any doc carrying a `hygiene: ignore`-style marker in its first 25 lines, or matching a glob in `<project>/.claude/.hygiene/ignore`. These are opted out deliberately (shared docs, audit logs, specs where "corrected" is the subject matter).

**(c) Scope to what you own.** Only reconcile docs you authored or substantially edited in this session, unless the user explicitly asked you to clean a specific doc. For anything else, propose rather than apply, regardless of mode: another agent or the user may own that doc's current state.

**(d) A vocabulary match is a lead, not a verdict.** Finding "corrected", "TODO", or a date in a doc is a review candidate, never proof the text should be deleted. Remove the narration about the edit; keep the decision itself, its rationale, research observations, quotes, and creative intent. "We corrected the launch date to March 3" narrates an edit, so strip it. "We're launching March 3 because retail partners need six weeks lead time" is a decision with its rationale, so keep it.

## Procedure

1. **Re-read the whole artifact fresh.** Do not trust your memory of what it says — open it and read it end to end. Drift hides in the sections you didn't touch this turn.

2. **Extract every factual claim and re-verify it against current evidence.** For each load-bearing statement (numbers, tool/system behavior, "X causes Y", "we do/don't have Z"): re-run the query, re-fetch the page, re-check the live state. **Strong confidence in an older claim is the cue to verify, not to skip** — a stale prior feels identical to a checked fact. (Pairs with the global "Verify Before Asserting" rule.)

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

3. **Reconcile contradictions.** If two parts of the doc disagree, find ground truth and fix *both* — don't leave the reader to guess which is current.

4. **Strip changelog / correction narration.** Remove edit-history scar tissue: "corrected", "reversed", "verified live on <date>", "an earlier draft claimed…", "⚠ correction", "now addressed", "(reversed 2026-..)", ✓-decision logs, and dated parentheticals that narrate *what changed*. The document states the **current truth**, not the story of its edits. If edit history matters, it belongs in version control or a separate CHANGELOG — not inline.

5. **Resolve stale markers.** Delete done TODO/FIXME/XXX; keep only ones still real, with a reason. A marker written as `TODO(<reason>)` (the marker immediately followed by a parenthesized reason, e.g. `TODO(keep until v2 ships)`) is a deliberately kept marker, not a scar; leave it. A bare `TODO`/`FIXME`/`XXX`/`HACK` with no reason attached is a scar candidate: resolve it or give it one.

6. **Check structural integrity after edits.** Cross-references, section numbers/letters, link targets, and tier/item IDs still line up. Renumbering drift is common after insertions/deletions.

7. **Deterministic scar scan.** Strip justified markers first, then confirm it's clean:
   ```
   sed -E 's/(TODO|FIXME|XXX|HACK)\([^)]*\)//g' <file> | grep -nEi 'correction|corrected|reversed|verified live|earlier draft|previously (said|claimed)|no longer (true|accurate)|now addressed|decisions logged|⚠|TODO|FIXME|XXX|HACK'
   ```
   Expect no matches. A `TODO(<reason>)`-style marker is stripped before the scan and is not a match to chase.

8. **Fresh-reader test.** Would someone with zero session history read this as one coherent current document — no contradictions, no "wait, which claim is right?", no visible edit scars? If not, fix what they'd trip on.

9. **Report according to mode.** In **apply** mode: housekeeping is your job, not a status update — run the pass and say nothing about it by default. Surface something only when it changes what the reader does: a claim you fixed that contradicts advice they already acted on, a decision only they can make, or a setting they need to change. When you do surface it, lead with that, not with a summary of what you pruned. In **propose** mode: present the compact change list from Step 0(a) and stop; do not apply anything until the user accepts.

## Anti-patterns
- Trusting your own summary of the doc instead of re-reading it.
- "Fixing" only the section the user pointed at, leaving the same stale claim elsewhere.
- Replacing a wrong claim with a *new* unverified claim (verify the replacement too).
- Turning the doc into a changelog ("was X, now Y, corrected on Z") — that IS the scar.
