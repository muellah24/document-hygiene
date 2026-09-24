<!-- hygiene: ignore --><!-- this reference discusses the staleness evaluator's own vocabulary (backlog, todo, done, etc.) as subject matter, not as drift in the doc itself -->

# Generic recipe: any other PM tool

`bin/check-staleness` doesn't know about Linear, Jira, Notion, GitHub Projects, or Asana. It only knows the JSON shape described in the script's own header comment. A recipe for a tool with no dedicated reference file here is exactly this: produce that JSON from whatever API or export the tool offers, and deliver the result as a comment.

## The five fields any tool must provide, per issue

- `id`: a short token matching `[A-Z][A-Z0-9]+-[0-9]+` (letters, then a hyphen, then digits) if you want T1/T1b/T4's doc-text matching to find it by scanning; otherwise the evaluator still runs T2/T3 correctly (they don't need doc-text matching), but T1/T1b/T4 will never fire for that issue since its ID never "appears" anywhere. Most trackers already use this shape (`TECH-1317`, `PROJ-42`); a tool that doesn't (a bare numeric ID, a UUID) needs its own ID scheme translated to something ID-shaped before this evaluator is useful for it.
- `state`: the tool's own status label, as text (used only for the `detail` message the evaluator writes, e.g. `"issue is completed"` reads more usefully than `"issue is done_category_3"`).
- `stateType`: one of `backlog`, `unstarted`, `started`, `completed`, `canceled` (Linear's vocabulary, adopted as the evaluator's fixed vocabulary; every recipe maps its tool's own categories onto this five-way set).
- `createdAt`, `updatedAt`: ISO-8601 timestamps. A bare `yyyy-MM-dd` (no time) works too: the evaluator appends a `Z` and treats it as midnight UTC, which is enough precision for T2/T3/T4's day-granularity comparisons but too coarse for T1b's ordering check against `doc.updatedAt` on the same day.

`title` is optional (used nowhere in T1-T4, only worth including if your own delivery step wants a human-readable label in the comment).

The document side needs exactly two fields: `text` (the full body, plain text or Markdown; HTML is not stripped by the evaluator, so strip it yourself if your tool stores rich text as HTML) and `updatedAt` (same ISO-8601 shape as above).

## stateType mapping table by tool (all unverified: not checked against each vendor's own API reference in this pass)

| Tool | Status source | Suggested stateType mapping | Verified? |
|---|---|---|---|
| Notion | The built-in "Status" property type groups its options into three fixed groups (commonly labeled To-do / In Progress / Complete, renameable per database) | To-do group -> `unstarted`; In Progress group -> `started`; Complete group -> `completed`; no first-class `canceled` or `backlog` (model a "Cancelled" option, if the database has one, as a synthetic `canceled` by name match) | No: not checked against Notion's API reference in this pass |
| GitHub Projects (v2) | A custom single-select "Status" field with project-defined options (commonly Todo / In Progress / Done, but not a fixed vocabulary the way Linear's stateType is), plus the linked issue or PR's own `state` (open/closed) and `merged` | Map by the project's own option names, case-insensitively, onto the same three buckets; treat a closed-not-merged PR or a closed "not planned" issue as `canceled` | No: not checked against GitHub's REST/GraphQL API reference in this pass |
| Asana | Tasks have a `completed` boolean and `completed_at`, not a three-way category; a custom "Status" field or section membership (e.g. a "Done" section) is often used as a proxy for stage | `completed: true` -> `completed`; otherwise fall back to section name or a custom field, mapped the same way as GitHub Projects above | No: not checked against Asana's API reference in this pass |

Before trusting a mapping in this table for a real recipe, check it against the vendor's current API reference: status vocabularies are exactly the kind of detail vendors change without much notice, and this table was written from general knowledge, not a live fetch.

## Delivery and scheduling

Same rules as every other PM-doc path (see `SKILL.md`, "Living documents in project-management tools"): propose-only, delivered as a comment (every PM tool in this table has some form of commenting), never written into the doc, and a recurring check is offered on first manual use, never created unasked. What "as a comment" means concretely is tool-specific: a Notion page comment, a GitHub Projects item comment (or an issue comment, if the doc is an issue body), an Asana task/project comment. Write the analogous recipe for whichever of these five sections you're building against `references/linear.md`'s shape (fetch doc, fetch issues, map stateType, build the evaluator's JSON, deliver as comment, offer scheduling) once you've verified the specifics.
