<!-- hygiene: ignore --><!-- this reference discusses the staleness evaluator's own vocabulary (backlog, todo, done, etc.) as subject matter, not as drift in the doc itself -->

# Jira recipe

How to feed a Jira (or Jira + Confluence) project doc into `bin/check-staleness`, and how to deliver the result. Jira's own REST reference lives at `developer.atlassian.com` (not `docs.atlassian.com`, which is a different, older documentation stack); every fact below is flagged verified (checked against `developer.atlassian.com`, `support.atlassian.com`, or corroborated across multiple independent sources during this write-up) or **unverified** (plausible from general Jira knowledge, not checked against a vendor page in this pass).

## 1. Fetch the document

Jira issues carry a plain-text/ADF `description`, which can serve as a "current state" doc for a single issue, but a project-level doc more commonly lives in a linked Confluence page. Either way, get its content and its own "last updated" timestamp:
- **Jira issue description**: `GET /rest/api/3/issue/<key>` (fields: `description`, `updated`). *Verified*: this endpoint and these field names are the standard Jira Cloud issue-read shape.
- **Confluence page**: use Confluence's own content API (`GET /wiki/rest/api/content/<id>?expand=body.storage,version`) for the body and `version.when` (its update timestamp). *Unverified in this pass*: Confluence's REST API wasn't checked against its own reference during this write-up; the endpoint shape above is from general knowledge, not confirmed live.

## 2. Fetch the issues

**Verified**: `GET /rest/api/3/search` (and `POST /rest/api/3/search`) are deprecated and have been removed from Jira Cloud (return `410 Gone` with a message pointing at the replacement). The current endpoint is `/rest/api/3/search/jql` (GET or POST), and it paginates with a `nextPageToken` instead of the old `startAt`. Use `/rest/api/3/search/jql`, not `/rest/api/3/search`, for any new integration.

JQL query shape:
```
project = TECH AND updated >= "2026-09-23 07:48"
```

**Verified**: JQL date/time literals accept exactly four hard-coded formats: `yyyy/MM/dd HH:mm`, `yyyy-MM-dd HH:mm`, `yyyy/MM/dd`, `yyyy-MM-dd`. There is no ISO-8601 form with `T` or a trailing `Z`, and no explicit timezone in the literal; the value is interpreted in the searching user's (or the Jira instance's) configured timezone. This means `doc.updatedAt` (an ISO-8601 UTC instant like `2026-09-23T07:48:49Z`) cannot be passed to JQL as-is: convert it to `yyyy-MM-dd HH:mm` in the relevant timezone first, and expect the granularity to be minutes, not seconds. A JQL-side pre-filter is therefore approximate (it narrows to "changed on or after this minute, in this timezone"); `bin/check-staleness` still needs each returned issue's exact `updated` timestamp to do the real T1-T4 comparisons.

Per-issue fields to request (via the `fields` parameter on the search call, or `GET /rest/api/3/issue/<key>` for one issue): `summary`, `status`, `created`, `updated`, `resolutiondate`, `parent`.

## 3. Map Jira's status vocabulary onto the evaluator's stateType

**Verified**: every Jira status has a `statusCategory` with a `key` that is one of `new`, `indeterminate`, `done`, or `undefined` (`undefined` is the fallback when a status has no category, rare in practice). Map by `statusCategory.key`, never by the status's own display name: display names are workflow-specific and localized ("To Do", "Sprint Backlog", "En curso" all exist across different Jira sites), but the category key is stable.

| Jira `statusCategory.key` | evaluator `stateType` |
|---|---|
| `new` | `unstarted` |
| `indeterminate` | `started` |
| `done` | `completed` |
| `undefined` | `unstarted` (safest default: treat an uncategorized status as not-yet-started rather than silently dropping it) |

Jira has no first-class `canceled`/`backlog` split the way Linear does: a "Cancelled" or "Won't Do" status is usually still categorized `done` by the workflow (it's a terminal state), which would make a canceled Jira issue look `completed` to the evaluator and get counted toward T2/T4 instead of excluded. **Unverified in this pass, but a known Jira modeling gap**: if the recipe needs the same "ignore canceled work" behavior Linear gets for free, check each issue's `resolution` field (a resolution of `"Won't Do"`/`"Cancelled"`, name varies by site) and remap those to a synthetic `canceled` stateType before handing the array to `bin/check-staleness`, rather than trusting `statusCategory.key` alone.

`id` for the evaluator's per-issue matching should be the issue key (e.g. `TECH-1317`), which is exactly the token `bin/check-staleness`'s `[A-Z][A-Z0-9]+-[0-9]+` pattern looks for in the doc text; Jira issue keys already have this shape by construction.

## 4. Build the evaluator's JSON

```bash
jq -n --slurpfile issues jira-issues.json --arg text "$(cat doc-content.md)" --arg updated "$DOC_UPDATED_AT" '
def statecat($k): if $k == "new" then "unstarted" elif $k == "indeterminate" then "started" elif $k == "done" then "completed" else "unstarted" end;
{
  doc: {text: $text, updatedAt: $updated},
  issues: [ $issues[0][] | {
    id: .key,
    title: .fields.summary,
    state: .fields.status.name,
    stateType: (.fields.status.statusCategory.key | statecat(.)),
    createdAt: .fields.created,
    updatedAt: .fields.updated
  } ]
}
' | bin/check-staleness
```

(`jira-issues.json` is the raw array of issues from `/rest/api/3/search/jql`'s `issues` field; adjust the `jq` path if your fetch already unwraps that envelope. Jira's `created`/`updated` fields are ISO-8601 with a numeric offset, e.g. `2026-09-23T07:48:49.000+0000`; `bin/check-staleness`'s date handling accepts a numeric UTC offset directly, no separate conversion needed for this step, only for the JQL query string in step 2.)

## 5. Delivering the result

Propose-only, same as every PM-doc path: never write the fix into the issue description or Confluence page. Post it as a comment instead:
- **On a Jira issue**: `POST /rest/api/3/issue/<key>/comment` with the proposal as the comment body (Atlassian Document Format, not plain Markdown, for the Cloud v3 API). *Verified*: this is the standard Jira Cloud comment-creation endpoint shape.
- **On a Confluence page**: Confluence's own comment API. *Unverified in this pass*.

Confirm with the user before posting: this is a "send a message on the user's behalf" action.

## 6. Wiring the trigger to a clock or event

- **Jira Automation, "issue transitioned" rule**: a project automation rule triggered on issue transition (or on a schedule) that calls a webhook pointed at whatever runs steps 1-4. **Unverified in this pass**: Jira Automation's trigger catalog and its webhook-action configuration weren't checked against `support.atlassian.com`'s automation docs during this write-up; this is standard Jira Automation capability from general knowledge, not a confirmed exact trigger name.
- A scheduled external job (cron, a Claude Code scheduled task) that re-runs steps 1-4 on an interval is the tool-independent fallback and needs no Jira-side configuration at all.
