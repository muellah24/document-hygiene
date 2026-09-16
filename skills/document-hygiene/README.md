<!-- hygiene: ignore --><!-- this README documents the hygiene tool's own trigger vocabulary (corrected/reversed/TODO/etc.) as subject matter, not as drift in the doc itself -->

# Document Hygiene (skill)

Keeps long-lived Markdown documents (plans, specs, reports, READMEs) free of stale claims, contradictions, and changelog narration. Re-reads the whole document, re-verifies every factual claim, fixes contradictions, and removes edit-history scar text ("corrected", "reversed", "TODO", etc.) so the document reads as one current, accurate version instead of a sediment of patches.

For anyone maintaining a project doc with AI, not only engineers: product managers, project managers, product owners, scrum masters, founders, vibe coders. A launch plan, a spec, a status report all rot the same way a README does.

## What it does

- **Preflight first** (Step 0 in SKILL.md): resolves the mode, skips exempt docs, and scopes work to what the agent actually authored this session.
- Re-reads the full document instead of trusting a memory of it.
- Re-verifies each factual claim against current evidence (a query, a fetch, a live check), including PM-shaped drift: owners, dates, scope, phase/dependency status, metrics and targets, decisions, counts, tool/file names.
- Finds contradictions between sections and fixes both sides, not just the one flagged.
- Deletes changelog-style narration ("was X, now Y, corrected on Z"): edit history belongs in version control, not inline.
- Removes resolved TODO/FIXME/XXX markers; keeps only ones still real, with a reason. A marker written `TODO(<reason>)` is treated as deliberately kept, not a scar.
- Checks that cross-references, numbering, and links still line up after edits.
- Finishes with a deterministic `grep` scar-scan before reporting done.

Full step-by-step procedure: [SKILL.md](SKILL.md).

## Modes

- **propose** (default): lists proposed changes (current text, proposed text, evidence) and waits for approval before editing.
- **apply**: edits directly, reports only what needs a human.

Resolution order: env var `DOCUMENT_HYGIENE_MODE` → `<project>/.claude/.hygiene/mode` → `~/.claude/document-hygiene/mode` → default `propose`. Switch with `echo apply > .claude/.hygiene/mode` (project) or `echo apply > ~/.claude/document-hygiene/mode` (global). Use `apply` solo; keep `propose` in a multi-agent or shared folder, where an unreviewed edit costs more than a short approval step.

## When it runs

- **Manually**: ask "clean up this doc", "is this still accurate", "remove the correction scars", or invoke it right after reversing/correcting a claim (drift clusters, so the same stale claim usually needs fixing elsewhere too).
- **Automatically**: via a companion `Stop` hook that fires once a session has made 5+ edits to a `.md`/`.mdx` file, or as soon as a scar marker (`corrected`, `reversed`, `TODO`, `⚠`, …) shows up in one it touched.

The automatic trigger needs the two hooks that live at the repo root (`hooks/track-doc-edits.sh`, `hooks/check-doc-hygiene.sh`): they are not part of this folder. Copying only `skills/document-hygiene/` gives you the skill for manual invocation; it will not fire on its own. Install the hooks too for automatic enforcement: see the [repo README](../../README.md#install).

## Files in this folder

| File | Purpose |
|---|---|
| `SKILL.md` | The procedure Claude follows. Its frontmatter `description` is also what makes Claude auto-select this skill for matching requests. |

## Standalone install (skill only, no automatic trigger)

```bash
cp -r skills/document-hygiene ~/.claude/skills/document-hygiene
```

## Implementation notes

- A document opts out of tracking with a top-of-file marker in its first 25 lines: `<!-- hygiene: ignore -->` (also accepts `skip`, `collaborative`, `shared`, `audit`, `log`), or via a project-level glob list at `.claude/.hygiene/ignore`. Use this for audit logs or specs where words like "corrected" are the subject matter, not drift.
- A `TODO`/`FIXME`/`XXX`/`HACK` written as `TODO(<reason>)` is a justified, deliberately kept marker, not a scar: both hooks strip that pattern before scanning. A bare marker with no reason still counts.
- A file inside the project is always tracked, even when the project itself lives under `/tmp` or `/var/folders`; both paths are canonicalized before comparison so the temp/cache skip only fires for files genuinely outside the project.
- Runtime tracking state (edit counts, touched/scarred docs) lives outside any project, at `~/.claude/document-hygiene/state/<project-hash>/sessions/<session_id>/`, never inside the repo being edited, and namespaced per session so concurrent agents don't share counters.
- The Stop hook exits without emitting when `stop_hook_active` is `true` (Claude Code is already continuing because this same Stop hook fired), so its own cleanup edits can't retrigger it.
- The scar-scan regex (step 7 in `SKILL.md`) is the deterministic ground truth for "is this document clean":
  ```
  correction|corrected|reversed|verified live|earlier draft|previously (said|claimed)|no longer (true|accurate)|now addressed|decisions logged|⚠|TODO|FIXME|XXX|HACK
  ```

## Source

https://github.com/muellah24/document-hygiene
