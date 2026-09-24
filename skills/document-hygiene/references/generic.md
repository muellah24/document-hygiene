<!-- hygiene: ignore --><!-- this reference discusses the staleness evaluator's own vocabulary (backlog, todo, done, etc.) as subject matter, not as drift in the doc itself -->

# Generic recipe: any other PM tool

`bin/check-staleness` doesn't know about Linear, Jira, Notion, GitHub Projects, or Asana. It only knows the JSON shape described in the script's own header comment. A recipe for a tool with no dedicated reference file here is exactly this: produce that JSON from whatever API or export the tool offers, and deliver the result as a comment.

## The five fields any tool must provide, per issue

- `id`: a short token matching `^[A-Za-z][A-Za-z0-9_]*-[0-9]+$` (a letter, then letters/digits/underscores, then a hyphen, then digits): `bin/check-staleness` validates this shape strictly and exits 2 on anything else, so an ID that doesn't match is a hard error, not a rule that quietly never fires. Most trackers already use this shape (`TECH-1317`, `PROJ-42`); a tool that doesn't (a bare numeric ID, a UUID) needs its own ID scheme translated to something ID-shaped before this evaluator is usable for it at all. Doc-text matching (T1/T1b/T4) is case-insensitive and token-bounded: an id is found whether it appears verbatim, lowercased, or embedded in a URL, as long as the character immediately before and after it in the text is not a letter, digit, or underscore.
- `state`: the tool's own status label, as text (used only for the `detail` message the evaluator writes, e.g. `"issue is completed"` reads more usefully than `"issue is done_category_3"`).
- `stateType`: one of `backlog`, `unstarted`, `started`, `completed`, `canceled` (Linear's vocabulary, adopted as the evaluator's fixed vocabulary; every recipe maps its tool's own categories onto this five-way set).
- `createdAt`, `updatedAt`: ISO-8601 timestamps (`Z`, a numeric UTC offset with or without a colon, fractional seconds, or no offset at all, all accepted and calendar-checked). A bare `yyyy-MM-dd` (no time) works too: the evaluator treats it as midnight UTC, which is enough precision for T2/T3/T4's day-granularity comparisons but too coarse for T1b's ordering check against `doc.updatedAt` on the same day.

`title` is optional (used nowhere in T1-T4, only worth including if your own delivery step wants a human-readable label in the comment).

The document side needs exactly two fields: `text` (the full body, plain text or Markdown; HTML is not stripped by the evaluator, so strip it yourself if your tool stores rich text as HTML) and `updatedAt` (same ISO-8601 shape as above).

**Fetch every issue in the project on every run, not only those updated recently.** T1 needs to see a ticket that was completed BEFORE the doc's own last edit but that the doc still calls "planned"; a fetch narrowed to "updated since the doc" removes exactly the evidence T1 exists to catch. If the tool's own API makes a full scan too slow for a large project, a recency filter may be used as a first-pass optimization only when unioned with every issue id the doc text already references (see `references/jira.md`'s equivalent note for a worked example of the union).

## stateType mapping table by tool (all unverified: not checked against each vendor's own API reference in this pass)

| Tool | Status source | Suggested stateType mapping | Verified? |
|---|---|---|---|
| Notion | The built-in "Status" property type groups its options into three fixed groups (commonly labeled To-do / In Progress / Complete, renameable per database) | To-do group -> `unstarted`; In Progress group -> `started`; Complete group -> `completed`; no first-class `canceled` or `backlog` (model a "Cancelled" option, if the database has one, as a synthetic `canceled` by name match) | No: not checked against Notion's API reference in this pass |
| GitHub Projects (v2) | A custom single-select "Status" field with project-defined options (commonly Todo / In Progress / Done, but not a fixed vocabulary the way Linear's stateType is), plus the linked issue or PR's own `state` (open/closed) and `merged` | Map by the project's own option names, case-insensitively, onto the same three buckets; treat a closed-not-merged PR or a closed "not planned" issue as `canceled` | No: not checked against GitHub's REST/GraphQL API reference in this pass |
| Asana | Tasks have a `completed` boolean and `completed_at`, not a three-way category; a custom "Status" field or section membership (e.g. a "Done" section) is often used as a proxy for stage | `completed: true` -> `completed`; otherwise fall back to section name or a custom field, mapped the same way as GitHub Projects above | No: not checked against Asana's API reference in this pass |

Before trusting a mapping in this table for a real recipe, check it against the vendor's current API reference: status vocabularies are exactly the kind of detail vendors change without much notice, and this table was written from general knowledge, not a live fetch.

## Delivery and scheduling

Same rules as every other PM-doc path (see `SKILL.md`, "Living documents in project-management tools"): propose-only, delivered as a comment (every PM tool in this table has some form of commenting), never written into the doc, and a recurring check is offered on first manual use, never created unasked. What "as a comment" means concretely is tool-specific: a Notion page comment, a GitHub Projects item comment (or an issue comment, if the doc is an issue body), an Asana task/project comment. Write the analogous recipe for whichever of these five sections you're building against `references/linear.md`'s shape (fetch doc, fetch issues, map stateType, build the evaluator's JSON, deliver as comment, offer scheduling) once you've verified the specifics.

**Skip a repeat comment before posting, regardless of tool.** Compute the fingerprint described in `SKILL.md`'s "Skip a repeat comment" section (`doc.updatedAt` plus the sorted, unique `rule:issue` pairs from `bin/check-staleness`'s `.reasons`, SHA-256, first 12 hex chars), list the existing comments on the doc or project (paged through to the end, not only the first page, whatever pagination shape that tool uses), and skip posting if one already contains the exact line `hygiene-fingerprint: <that hash>`. Running the check on a schedule and posting a comment are two separate authorisations (the first read-only, the second a message sent on the user's behalf); neither implies the other, whichever tool this recipe targets.
