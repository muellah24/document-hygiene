<!-- hygiene: ignore --><!-- this README documents the hygiene tool's own trigger vocabulary (corrected/reversed/TODO/etc.) as subject matter, not as drift in the doc itself -->

# Document Hygiene

An AI agent editing a long document patches only the paragraph in front of it, so after weeks the plan, spec, or README it maintains contradicts itself and nobody notices. Document Hygiene is a Claude Code skill and hook pair that makes Claude re-read, re-verify, and reconcile the whole document when a session has edited it heavily. It proposes fixes by default (you approve them) and can be switched to apply them directly, with your git history as the only undo. It never blocks a session, stores no document content, and runs no external service. It's for anyone who runs a project with a goal and keeps a living document about it: product managers, project managers, product owners, scrum masters, founders, vibe coders, and engineers alike.

![Document Hygiene](docs/document-hygiene-comic.jpg)

[Full resolution](docs/document-hygiene-comic-FULL.jpg) · Explainer video: [`docs/document-hygiene-promo.mp4`](docs/document-hygiene-promo.mp4)

## What you get

- **A reminder at the end of a turn**: the Stop hook checks, when a turn finishes, whether the session has made 5+ edits to a Markdown doc or left a scar marker (`corrected`, bare `TODO`, etc.) in one of them (docs that opted out don't count). Detection is not real time: nothing happens mid-turn, only at the end, when the Stop event fires.
- **A disciplined reconciliation procedure**: on that reminder, Claude re-reads the whole document, re-verifies every claim against current evidence, fixes contradictions on both sides, and strips changelog narration.
- **Safe defaults**: nothing is edited without your say-so unless you deliberately switch modes, and even then, only inside a git safety net.

### Safety, in six lines

- Never blocks a session: it only reminds.
- Stores no document content anywhere, only edit counts and file paths, under `~/.claude`.
- Proposes changes by default; you approve them.
- Apply mode edits only a doc that is saved in git with no pending changes (committed and clean), and prints the exact `git restore` command before touching it.
- Any doc can opt out with a one-line marker.
- Covered by a regression suite (see Tests).

## Why documents drift

Short-lived docs don't drift: you write them once and move on. The ones that rot are the docs a project leans on for weeks: the spec, the plan, the architecture note, the README, edited over and over.

When an AI agent edits a long doc, it does the economical thing: it rewrites the span the current task touches and leaves the rest alone. That's right for the immediate ask and wrong for the document: fifty patches later, the doc is a sediment of half-updated truths.

Each project change lands as a *patch*, not a *rewrite*:

- **A decision reverses.** You switch Postgres to DynamoDB in week three. "Data model" gets updated; "Overview" still says Postgres.
- **A person leaves.** The launch plan still says Priya owns onboarding; Priya left in May.
- **A thing gets renamed.** The install step calls `setup.sh`; the script is now `bootstrap.sh`. It wasn't wrong when written. The world moved.
- **The edits narrate themselves.** The doc accumulates its own diff: "corrected the endpoint (was /v1, now /v2)", burying the current answer under the story of how it changed.

A drifted doc is worse than no doc, because people and agents still trust it: one contradiction and the reader re-verifies everything by hand anyway, the next AI session inherits a stale claim and builds on it, and the longer it's left the more expensive the untangle.

Patching is not reconciling. This tool watches the sediment build up and prompts a reconciliation pass: re-read the whole thing, re-verify every claim, fix both sides of each contradiction, strip the changelog scars.

## How it works

Three pieces, all Claude Code native (no external service):

1. **`hooks/track-doc-edits.sh`** (`PostToolUse` on `Edit|Write|MultiEdit`): counts edits to touched `.md`/`.mdx`/`.markdown` files and flags scar markers in them, namespaced per Claude session so concurrent agents never share counters or get blamed for each other's edits.
2. **`hooks/check-doc-hygiene.sh`** (`Stop` hook): when a session ends, if it made 5+ doc edits or hit a scar marker and at least one non-exempt doc remains in scope, injects a reminder naming exactly which docs to reconcile and the current mode.
3. **`skills/document-hygiene/SKILL.md`**: the procedure Claude follows on that reminder, or on request ("clean up this doc", "is this still accurate"): re-read the whole doc, re-verify every claim, reconcile contradictions, strip changelog narration, resolve stale TODOs, check structural integrity, then a deterministic scar scan before reporting.

### What a reminder looks like

Example: apply mode, one doc edited 6 times this session with a leftover bare `TODO`, in a repo at `/Users/you/project`. The Stop hook injects this as additional context (wrapped below for readability; only the line break before `restore:` is a real one, from the hook's own output):

```
Document-hygiene check due: 6 doc edit(s) since the last pass (this session
only). Drift/changelog markers found in:
/Users/you/project/docs/launch-plan.md. Touched docs:
/Users/you/project/docs/launch-plan.md. These are only docs YOU edited this
session. Skip any doc you did not author this session or that carries a
'hygiene: ignore' marker (another agent may own it). Otherwise run the
document-hygiene skill on the rest: fact-check every claim against current
evidence, delete stale/contradicted statements and changelog narration, so
each doc reads as a clean current version. Mode: apply (edit directly; when
nothing needs a human, reply with the single line 'Hygiene pass: ok' and
nothing more).
restore: git -C /Users/you/project restore --source=1a2b3c4d5e6f7089abcdef1234567890fedcba98 --worktree -- docs/launch-plan.md
```

Note the two path styles: `Touched docs` and `Drift/changelog markers found in` show the file path as Claude's tools recorded it (absolute); the restore command's target, after `--`, is repo-relative, because `git restore` expects a path relative to the repo root it's run against.

## Modes

- **propose** (default): Claude re-reads and re-verifies as usual but doesn't edit the doc. It presents a compact list of proposed changes (current text, proposed text, evidence) and waits for you to accept.
- **apply**: Claude edits directly, but only a doc that's committed and clean in git; anything else gets proposed instead even though the session mode is apply. When nothing needs you, Claude replies with one line, `Hygiene pass: ok`.

Resolution order, first match wins: env var `DOCUMENT_HYGIENE_MODE` → `<project>/.claude/.hygiene/mode` → `~/.claude/document-hygiene/mode` → default `propose`. Parsing fails closed: once a source is picked (the env var is set, or a mode file exists), an empty or malformed value there resolves to `propose` directly, rather than falling through to a lower-priority source.

Switch it:
```bash
# Project-level (this repo/folder only)
mkdir -p .claude/.hygiene && echo apply > .claude/.hygiene/mode

# Global (every project)
mkdir -p ~/.claude/document-hygiene && echo apply > ~/.claude/document-hygiene/mode

# One-off (this command only)
DOCUMENT_HYGIENE_MODE=apply claude ...
```
Pick `apply` for solo work, where reviewing every proposal is pure overhead. Keep `propose` (the default) in a multi-agent folder or shared doc, where an unreviewed automatic edit is more disruptive than a short approval step.

### Recovery: git is the only undo

This tool stores no document content anywhere, not even temporarily: no backup, no versioning, nothing under `~/.claude` beyond edit counts and file paths. Recovery relies entirely on your own git history.

"Git" here means the local save-history inside your project folder (the hidden `.git` directory), not GitHub. Every commit is a snapshot kept on your own disk, and the undo below reads from that snapshot. GitHub is not involved: nothing is pushed, fetched, or read from any server. If a folder is not a git repository yet, or a doc in it has never been committed, apply mode leaves that doc in propose mode; a one-time `git init` and commit is all it takes to enable the automatic path, and you can ask Claude to do that for you. Before editing a doc in apply mode, the Stop-hook reminder (and the skill, run manually) confirm the doc is committed and clean, then name the exact command that undoes the edit:
```
restore: git -C <repo-root> restore --source=<commit-sha> --worktree -- <path-relative-to-repo>
```
A doc that isn't committed and clean is reported as `<doc>: not committed and clean, propose only` instead: it's edited only after you review and accept the change by hand.

## Install

Both hook scripts are short, plain bash (each under 250 lines); read them before wiring them in.

1. Copy the skill:
   ```bash
   cp -r skills/document-hygiene ~/.claude/skills/document-hygiene
   ```
2. Copy the hooks:
   ```bash
   cp hooks/track-doc-edits.sh hooks/check-doc-hygiene.sh ~/.claude/hooks/
   chmod +x ~/.claude/hooks/track-doc-edits.sh ~/.claude/hooks/check-doc-hygiene.sh
   ```
3. Wire the hooks in. Pick a scope, project first:

   **Project only (recommended to start)**: add this to `<project>/.claude/settings.json` (create the file if it doesn't exist), so the hooks run only in that project:
   ```json
   {
     "hooks": {
       "PostToolUse": [
         {
           "matcher": "Edit|Write|MultiEdit",
           "hooks": [{ "type": "command", "command": "bash \"/Users/<you>/.claude/hooks/track-doc-edits.sh\"" }]
         }
       ],
       "Stop": [
         {
           "hooks": [{ "type": "command", "command": "bash \"/Users/<you>/.claude/hooks/check-doc-hygiene.sh\"" }]
         }
       ]
     }
   }
   ```

   **Every project**: add the same block to `~/.claude/settings.json` instead. The tracker then runs briefly on every Edit/Write in every project, exiting immediately for non-Markdown files.

   Replace `/Users/<you>` with your home directory (`/Users/<name>` on macOS, `/home/<name>` on Linux). If the settings file already has `PostToolUse`/`Stop` entries, add these as additional array items rather than replacing what's there.

   If you would rather not hand-edit JSON, paste the block into Claude Code and ask it to merge these two hook entries into the settings file for you.
4. Restart Claude Code (or start a new session) so the hooks load.

## Verify the install

1. From the cloned repo, run `bash tests/run.sh`: it confirms both hooks run correctly on this machine (a throwaway `HOME`, touches nothing real).
2. Start a new Claude Code session and run `/hooks`: `PostToolUse` and `Stop` should each show at least one configured hook.
3. End to end: ask Claude to create a scratch Markdown file containing a bare `TODO` line, then finish its turn. When it finishes, the Stop hook injects the reminder, and Claude should come back proposing to resolve or justify that `TODO` (in the default propose mode). Delete the scratch file afterward.

## Uninstall

1. Remove the two hook entries from wherever you added them (`~/.claude/settings.json` or `<project>/.claude/settings.json`).
2. Delete the two hook files, the skill folder, and the runtime state and mode files:
   ```bash
   rm ~/.claude/hooks/track-doc-edits.sh ~/.claude/hooks/check-doc-hygiene.sh
   rm -rf ~/.claude/skills/document-hygiene ~/.claude/document-hygiene
   ```

Nothing else was written anywhere, except any `.claude/.hygiene/` mode or ignore files you created yourself inside a project; remove those by hand if you want them gone.

## Configuration

- **Opt out a doc**: add `<!-- hygiene: ignore -->` (also accepts `skip`, `collaborative`, `shared`, `audit`, `log`) in its first 25 lines.
- **Opt out a path pattern**: list globs in `.claude/.hygiene/ignore`, one per line. A subset of gitignore syntax: shell globs matched against the basename, the project-relative path, and the absolute path; a pattern ending in `/` is a directory prefix (matches anything under it, e.g. `docs/audit/` or `docs/audit/*`); no negation, no `**`.
- **Justified markers**: `TODO(<reason>)` (and `FIXME`/`XXX`/`HACK` the same way) is a deliberately kept marker, not a scar. A bare marker with no reason still counts as a scar candidate.
- **Authorship stamp** (optional, for shared docs): prepend an HTML-comment block when substantially editing a doc other agents may also touch, e.g.:
  ```
  <!-- authors (newest first):
  - Claude Opus 4.8 · effort high · 2026-07-02 · drafted sections 1-4
  -->
  ```
  The tracker strips this block before scanning for scars, so it's safe to leave in place.

## Multi-agent folders

- **Attribution is per session**: a reminder only ever lists docs *that session* edited, never a concurrent agent's work.
- **Main-agent edits only**: a subagent tool call carries its own `agent_id` and is skipped rather than credited to the parent session.
- **State lives outside the repo**: under `~/.claude/document-hygiene/state/`, keyed by project and session, so ordinary markdown edits never leave untracked bookkeeping files inside your project.
- **Hardened cleanup**: the session ID is sanitized against a strict allowlist before it's used to build the path the Stop hook deletes, and that deletion is fenced to its own state directory.

## Limits

- Markdown only: `.md`, `.mdx`, `.markdown`. Other formats aren't tracked.
- The hooks only remind; the reconciliation itself depends on Claude following the skill correctly.
- Coverage is main-agent edits only: subagent tool calls aren't tracked.
- The recovery check needs git and a doc that's already committed and clean; anything else falls back to propose mode regardless of the session's mode setting.
- Developed and tested on macOS and Linux shells (bash, jq); not on Windows.
- The tracker hook starts a short bash process (using jq) on every Edit, Write, or MultiEdit tool call; it exits immediately for anything that is not a Markdown file. Git is invoked only by the Stop hook, and only in apply mode.

## Requirements

- Claude Code with hooks support.
- `jq` and `bash` (both hook scripts depend on `jq` for parsing the hook JSON payload).
- `shasum` or `sha1sum` (used to key runtime state by project directory; `shasum` ships with macOS, `sha1sum` with most Linux distros). If neither is present, all projects share one state directory (still separated per session).
- `git`, optional: only for the apply-mode recovery check; without it every doc is handled in propose mode.

## Tests

`tests/run.sh` is a self-contained regression suite for both hooks (it runs against a throwaway `HOME`, never your real state). Run it with `bash tests/run.sh`; it prints PASS/FAIL per case and exits non-zero on any failure.

## License

MIT. See [LICENSE](LICENSE).
