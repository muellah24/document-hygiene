<!-- hygiene: ignore --><!-- this README documents the hygiene tool's own trigger vocabulary (corrected/reversed/TODO/etc.) as subject matter, not as drift in the doc itself -->

# Document Hygiene (skill)

Keeps long-lived Markdown documents (plans, specs, reports, READMEs) free of stale claims, contradictions, and changelog narration. Re-reads the whole document, re-verifies every factual claim, fixes contradictions, and removes edit-history scar text ("corrected", "reversed", "TODO", etc.) so the document reads as one current, accurate version instead of a sediment of patches.

## What it does

- Re-reads the full document instead of trusting a memory of it.
- Re-verifies each factual claim against current evidence (a query, a fetch, a live check).
- Finds contradictions between sections and fixes both sides, not just the one flagged.
- Deletes changelog-style narration ("was X, now Y, corrected on Z") — edit history belongs in version control, not inline.
- Removes resolved TODO/FIXME/XXX markers; keeps only ones still real, with a reason.
- Checks that cross-references, numbering, and links still line up after edits.
- Finishes with a deterministic `grep` scar-scan before reporting done.

Full step-by-step procedure: [SKILL.md](SKILL.md).

## When it runs

- **Manually** — ask "clean up this doc", "is this still accurate", "remove the correction scars", or invoke it right after reversing/correcting a claim (drift clusters, so the same stale claim usually needs fixing elsewhere too).
- **Automatically** — via a companion `Stop` hook that fires once a session has made 5+ edits to a `.md`/`.mdx` file, or as soon as a scar marker (`corrected`, `reversed`, `TODO`, `⚠`, …) shows up in one it touched.

The automatic trigger needs the two hooks that live at the repo root (`hooks/track-doc-edits.sh`, `hooks/check-doc-hygiene.sh`) — they are not part of this folder. Copying only `skills/document-hygiene/` gives you the skill for manual invocation; it will not fire on its own. Install the hooks too for automatic enforcement: see the [repo README](../../README.md#install).

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
- Runtime tracking state (edit counts, touched/scarred docs) lives outside any project, at `~/.claude/document-hygiene/state/<project-hash>/sessions/<session_id>/` — never inside the repo being edited, and namespaced per session so concurrent agents don't share counters.
- The scar-scan regex (step 7 in `SKILL.md`) is the deterministic ground truth for "is this document clean":
  ```
  correction|corrected|reversed|verified live|earlier draft|previously (said|claimed)|no longer (true|accurate)|now addressed|decisions logged|⚠|TODO|FIXME|XXX|HACK
  ```

## Source

https://github.com/muellah24/document-hygiene
