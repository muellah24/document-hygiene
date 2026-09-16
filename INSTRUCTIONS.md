<!-- hygiene: ignore --><!-- this file documents the hygiene tool's own trigger vocabulary (corrected/reversed/TODO/etc.) as subject matter, not as drift in the doc itself -->

# Document Hygiene: platform-neutral procedure

This is the document-hygiene reconciliation procedure written for any AI coding agent, not only Claude Code. It has no dependency on Claude-specific tool names or Claude Code's hook system. Use it standalone: paste it into an agent's instructions file, or follow it directly when asked to clean up a long-lived document.

Long-lived artifacts drift: each turn patches the immediate ask and leaves old text in place, so stale claims, self-contradictions, and changelog scars accumulate. Patching is not reconciling. This procedure reconciles an artifact back to a single, current, clean truth.

It applies to any project doc kept alive across turns or days, not just code: a launch plan, a product spec, a status report, a project README. If a project has a goal and keeps a living document about it, this is for that document, regardless of who or what is maintaining it: a product manager, project manager, product owner, scrum master, founder, engineer, or an AI agent.

## When to run

- A large number of edits have accumulated on the document since the last pass (a reasonable default is 5+ edits in one working session).
- Before presenting any maintained artifact as "done" or "updated".
- Immediately after reversing or correcting a claim: drift clusters, so the same stale claim is usually echoed elsewhere in the doc.
- A document has been edited many times across a long session or multiple days.
- Whenever asked directly: "clean up this doc", "is this still accurate", "remove the correction scars".

## Step 0: Preflight

Run this before touching any text.

**(a) Determine the mode.** Resolution order, first match wins:
1. Environment variable `DOCUMENT_HYGIENE_MODE`.
2. `<project>/.claude/.hygiene/mode` (project-level file, literal contents `propose` or `apply`).
3. `~/.claude/document-hygiene/mode` (global file, same format).
4. Default: `propose`.

Once a source is selected (the env var is set, or the project file exists, or the global file exists, in that order), an empty or malformed value there resolves to `propose` directly: it never falls through to a lower-priority source.

Resolve the project root consistently: prefer an explicit project-root environment variable your tooling provides, else the git repository root (`git rev-parse --show-toplevel`), else the current working directory.

- **propose** (default): re-read and re-verify as usual, but do not edit the doc. Present a compact list of proposed changes (for each: current text, proposed text, and the evidence behind the change) and wait for the user to accept before applying anything.
- **apply**: edit directly. Afterwards reply with the single line `Hygiene pass: ok` unless something needs the user (see step 9).

**(b) Skip exempt docs.** Skip any doc carrying a `hygiene: ignore`-style marker (also accepts `skip`, `collaborative`, `shared`, `audit`, `log`) in its first 25 lines, or matching a glob in `<project>/.claude/.hygiene/ignore`. These are opted out deliberately (shared docs, audit logs, specs where "corrected" is the subject matter).

**(c) Scope to what you own.** Automatic reconciliation (apply mode) is allowed only for docs you created in this session. For any pre-existing doc, apply-mode edits happen only when the user explicitly asked you, by name, to clean that doc; otherwise propose rather than apply, regardless of mode: another agent or the user may own that doc's current state.

**Bounded edits.** Whether proposing or applying:
- Re-read the doc immediately before editing it; do not trust an earlier read from this session.
- Make localized edits that replace an exact, unique span of existing text (never a full-file overwrite), so a changed preimage fails the edit instead of silently overwriting another agent's work.
- Every edit must be backed by a specific piece of evidence gathered in this pass. When the evidence is ambiguous, leave the text alone and propose instead of guessing.
- Before declaring done, review the diff (`git diff -- <doc>` when the doc is in a git work tree) and confirm no section heading disappeared unintentionally.
- A pass must never leave a doc half-edited across turns: finish or revert each doc within the same turn.

**(d) A vocabulary match is a lead, not a verdict.** Finding "corrected", "TODO", or a date in a doc is a review candidate, never proof the text should be deleted. Remove the narration about the edit; keep the decision itself, its rationale, research observations, quotes, and creative intent. "We corrected the launch date to March 3" narrates an edit, so strip it. "We're launching March 3 because retail partners need six weeks lead time" is a decision with its rationale, so keep it.

**(e) Recovery baseline (apply mode only).** This procedure stores no document content anywhere, not even temporarily: git is the only undo. Before editing a doc in apply mode, confirm all three with shell commands you run yourself:
1. The doc is inside a git work tree: `git -C "$(dirname "$f")" rev-parse --show-toplevel`.
2. It is a tracked regular file, not a symlink: `git ls-files --error-unmatch -- "$f"` and `test -L "$f"` (must fail, i.e. not a symlink).
3. It has no staged or unstaged changes for that path: `git status --porcelain -- "$f"` prints nothing.

If all three hold, record the commit (`git rev-parse HEAD`) and the repo-relative path, and keep the exact restore command ready, shell-quoted so it can be pasted and run as-is even when the path contains spaces:
```
git -C <root> restore --source=<sha> --worktree -- <relative-path>
```
Do not print it up front. Before the first edit, tell the user in three words that the undo exists: `Undo ready (git).` Print the full command only if the pass goes wrong or the user asks how to undo.

If any check fails, handle that doc in propose mode even though the session mode is apply, and say so in one line, naming the specific reason: not in a git repository, never committed, has uncommitted changes, is a symlink, or git not installed. When the reason is "not in a git repository", say so and offer to initialize git for the folder (one time: `git init`, add the docs, commit); never run `git init` unasked, because creating a `.git` directory in someone's folder (a synced or shared folder, for instance) is a visible change they must approve. Never auto-commit, never stash (`git stash create` writes objects; it is not storage-free and is not a durable recovery point).

## Procedure

1. **Re-read the whole artifact fresh.** Do not trust your memory of what it says: open it and read it end to end. Drift hides in the sections you didn't touch this turn.

2. **Extract every factual claim and re-verify it against current evidence.** For each load-bearing statement (numbers, tool/system behavior, "X causes Y", "we do/don't have Z"): re-run the query, re-fetch the page, re-check the live state. Strong confidence in an older claim is the cue to verify, not to skip: a stale prior feels identical to a checked fact.

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

3. **Reconcile contradictions.** If two parts of the doc disagree, find ground truth and fix *both*: don't leave the reader to guess which is current.

4. **Strip changelog / correction narration.** Remove edit-history scar tissue: "corrected", "reversed", "verified live on <date>", "an earlier draft claimed…", "⚠ correction", "now addressed", "(reversed 2026-..)", checkmark decision logs, and dated parentheticals that narrate *what changed*. The document states the **current truth**, not the story of its edits. If edit history matters, it belongs in version control or a separate CHANGELOG, not inline.

5. **Resolve stale markers.** Delete done TODO/FIXME/XXX; keep only ones still real, with a reason. A marker written as `TODO(<reason>)` (the marker immediately followed by a parenthesized reason, e.g. `TODO(keep until v2 ships)`) is a deliberately kept marker, not a scar; leave it. A bare `TODO`/`FIXME`/`XXX`/`HACK` with no reason attached is a scar candidate: resolve it or give it one.

6. **Check structural integrity after edits.** Cross-references, section numbers/letters, link targets, and tier/item IDs still line up. Renumbering drift is common after insertions/deletions.

7. **Deterministic scar scan.** This is a review list, not an auto-delete list: a hit is a candidate to look at, never by itself proof the text is wrong. Legitimate matches stay in place: a title, a code sample (`reversed(values)`), a quotation, a research or decision sentence ("the reversed order improved accuracy"), or an authorship block itself. Strip any authorship block and justified markers first, then scan:
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
