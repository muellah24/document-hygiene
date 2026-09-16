<!-- hygiene: ignore --><!-- this README documents the hygiene tool's own trigger vocabulary (corrected/reversed/TODO/etc.) as subject matter, not as drift in the doc itself -->

# Document Hygiene (skill)

Keeps a long-lived Markdown document (plan, spec, report, README) free of stale claims, contradictions, and changelog narration. Re-reads the whole document, re-verifies every claim, and reconciles it back into one clean, current version instead of a sediment of patches.

## What it does

- Re-reads the full document instead of trusting a memory of it.
- Re-verifies each factual claim against current evidence, including PM-shaped drift: owners, dates, scope, phase/dependency status, metrics, decisions, counts, tool/file names.
- Finds contradictions between sections and fixes both sides, not just the one flagged.
- Deletes changelog-style narration ("was X, now Y, corrected on Z"): edit history belongs in version control, not inline.
- Removes resolved TODO/FIXME/XXX markers; keeps only ones still real, with a reason (`TODO(<reason>)` is treated as deliberately kept).
- Finishes with a deterministic `grep` scar scan before reporting done.

Full step-by-step procedure: [SKILL.md](SKILL.md).

## When it runs

- **Manually**: ask "clean up this doc", "is this still accurate", "remove the correction scars", or invoke it right after reversing/correcting a claim.
- **Automatically**: via a companion `Stop` hook that fires once a session has made 5+ edits to a `.md`/`.mdx` file, or as soon as a scar marker shows up in one.

The automatic trigger needs the two hooks that live at the repo root (`hooks/track-doc-edits.sh`, `hooks/check-doc-hygiene.sh`); they are not part of this folder. Copying only this folder gives you manual invocation only.

## Install

```bash
cp -r skills/document-hygiene ~/.claude/skills/document-hygiene
```
For automatic triggering, also install the two hooks: see the [root README's Install section](../../README.md#install).

## Modes and safety

- **propose** (default): lists proposed changes and waits for approval.
- **apply**: edits directly, only a doc that's committed and clean in git (saved in git with no pending changes); switch with a one-line `.claude/.hygiene/mode` file.
- Git is the only undo: apply mode names the exact `git restore` command before it edits anything.
- No document content is stored anywhere, not even temporarily: only edit counts and file paths, under `~/.claude`.

Details: [root README, Modes](../../README.md#modes) and [Recovery](../../README.md#recovery-git-is-the-only-undo).

## Files

| File | Purpose |
|---|---|
| `SKILL.md` | The procedure Claude follows. Its frontmatter `description` is also what makes Claude auto-select this skill for matching requests. |

## Source

https://github.com/muellah24/document-hygiene
