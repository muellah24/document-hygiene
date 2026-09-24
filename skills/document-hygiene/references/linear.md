<!-- hygiene: ignore --><!-- this reference discusses the staleness evaluator's own vocabulary (backlog, todo, done, etc.) as subject matter, not as drift in the doc itself -->

# Linear recipe

How to feed a Linear project document into `bin/check-staleness`, and how to deliver the result. This file only describes shaping input and delivering output; the four trigger rules themselves live in `bin/check-staleness` and are described in `SKILL.md`.

Tool names and parameters below are checked against the Linear MCP tool schemas available in this environment as of September 2026. Field and parameter names can change with the MCP server's own version; re-check with the tool's own schema (or `list_issues`'s `fields` enum) if a call is rejected.

## 1. Fetch the document

- `get_project` with the project's name, ID, identifier (e.g. `P-ENG-123`), or slug as `query`, and `includeResources: true` to also get its documents, links, and attachments in one call.
- Or `list_documents` with `projectId` to enumerate a project's documents, then `get_document` with the chosen document's `id` or slug to get its full content and `updatedAt`.

Either way you need, from the document: `content` (the doc body, Markdown) and `updatedAt`.

## 2. Fetch the issues

`list_issues` with:
- `project`: the project's name, ID, identifier, or slug (same value forms as `get_project`'s `query`).
- `fields`: `["id", "title", "status", "statusType", "createdAt", "updatedAt", "completedAt", "parentId", "url"]`. `id` is always included even if you omit it from `fields`.
- `includeArchived: false` (default) unless you deliberately want archived issues counted too.
- Page with `cursor` if the project has more issues than one page (`limit`, default 50, max 250).

For a single issue's blocking/related/duplicate relations (useful for the "decisions vs later run reports" checklist item in `SKILL.md`, not for the four trigger rules themselves), use `get_issue` with `includeRelations: true`.

## 3. Build the evaluator's JSON

`list_issues` returns `status` (the status name, e.g. `"Done"`) and `statusType` (the category, e.g. `"completed"`). Linear's `statusType` values map 1:1 onto the evaluator's `stateType` vocabulary (`backlog`, `unstarted`, `started`, `completed`, `canceled`); only the JSON key changes, from `status`/`statusType` to `state`/`stateType`. A `jq` transform from the raw `list_issues` result to `check-staleness`'s input shape:

```bash
jq -n --slurpfile issues linear-issues.json --arg text "$(cat doc-content.md)" --arg updated "$DOC_UPDATED_AT" '
{
  doc: {text: $text, updatedAt: $updated},
  issues: [ $issues[0][] | {
    id: .id,
    title: .title,
    state: .status,
    stateType: .statusType,
    createdAt: .createdAt,
    updatedAt: .updatedAt
  } ]
}
' | bin/check-staleness
```

(`linear-issues.json` is the array `list_issues` returned; `doc-content.md` is the document's `content` field written to a file so `$(cat ...)` doesn't choke on a large body. Adjust the plumbing to whatever your harness makes convenient. `options.volumeThreshold` / `options.maxAgeDays` / `options.now` can be added to the top-level object; all three are optional.)

## 4. Delivering the result

`bin/check-staleness` only decides whether a pass is due and why; the reconciliation itself follows `SKILL.md`'s Step 2b and checklist, using `get_issue` (with `includeRelations: true` where relevant) to look up the specifics of any issue the trigger named. Never write into the document: PM docs are propose-only, no exceptions (see `SKILL.md`, "Living documents in project-management tools").

Post the proposal as a comment with `save_comment`:
- `body`: the proposed changes, Markdown, current text vs. proposed text vs. the issue evidence behind each one (the same shape as propose mode uses for a file-based doc).
- Exactly one of `documentId` or `projectId` as the target (both are valid `save_comment` parent references; a comment on either becomes a top-level discussion thread visible next to the doc or the project).

Confirm with the user before calling `save_comment`: posting a comment is a "send a message on the user's behalf" action, not a read.

## 5. Wiring the trigger to a clock or event

Documented here, not created by the skill; offer once, on first manual use for a given project, and only build the one the user picks:

- **Claude Code scheduled task**: a recurring task whose prompt is one line: `check whether the living docs of Linear project <name> are current, propose changes as a comment`. The task re-runs steps 1-4 above each time; it does not need to remember anything between runs, since T1-T4 are computed fresh from the doc's own `updatedAt` and the current issue graph.
- **Linear webhook on issue state change**: Linear can call a webhook when an issue's state changes; the receiving endpoint runs steps 1-4 for that issue's project. This is the lowest-latency option (fires close to the moment T1/T1b's underlying condition becomes true) but needs a webhook receiver, which is infrastructure outside this skill's scope.
- **Linear agent mention**: mentioning the Claude agent directly on the project or document (where that integration exists) as a manual, on-demand trigger, functionally identical to asking in a session.
