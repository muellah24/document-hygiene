---
name: document-hygiene
description: Use when maintaining a long-lived document, plan, spec, report, README, or any artifact edited across multiple turns or days — to fact-check it against current evidence, remove stale or contradicted claims, and strip accumulated changelog/correction narration so it reads as a clean current version. Trigger on "clean up this doc", "is this still accurate", "remove the correction scars", a doc edited many times, after reversing/correcting any earlier claim, or when the automatic Stop-hook hygiene reminder fires.
---

# Document Hygiene

Long-lived artifacts drift: each turn patches the immediate ask and leaves old text in place, so stale claims, self-contradictions, and changelog scars accumulate. Patching is not reconciling. This skill reconciles an artifact back to a single, current, clean truth.

## When to run
- The Stop-hook reminder fired (N+ doc edits, or drift markers detected).
- Before presenting any maintained artifact as "done" or "updated".
- Immediately after you reverse or correct a claim — drift clusters, so the same stale claim is usually echoed elsewhere in the doc.
- A document has been edited many times across a long session or multiple days.

## Procedure

1. **Re-read the whole artifact fresh.** Do not trust your memory of what it says — open it and read it end to end. Drift hides in the sections you didn't touch this turn.

2. **Extract every factual claim and re-verify it against current evidence.** For each load-bearing statement (numbers, tool/system behavior, "X causes Y", "we do/don't have Z"): re-run the query, re-fetch the page, re-check the live state. **Strong confidence in an older claim is the cue to verify, not to skip** — a stale prior feels identical to a checked fact. (Pairs with the global "Verify Before Asserting" rule.)

3. **Reconcile contradictions.** If two parts of the doc disagree, find ground truth and fix *both* — don't leave the reader to guess which is current.

4. **Strip changelog / correction narration.** Remove edit-history scar tissue: "corrected", "reversed", "verified live on <date>", "an earlier draft claimed…", "⚠ correction", "now addressed", "(reversed 2026-..)", ✓-decision logs, and dated parentheticals that narrate *what changed*. The document states the **current truth**, not the story of its edits. If edit history matters, it belongs in version control or a separate CHANGELOG — not inline.

5. **Resolve stale markers.** Delete done TODO/FIXME/XXX; keep only ones still real, with a reason.

6. **Check structural integrity after edits.** Cross-references, section numbers/letters, link targets, and tier/item IDs still line up. Renumbering drift is common after insertions/deletions.

7. **Deterministic scar scan.** Confirm it's clean:
   ```
   grep -nEi 'correction|corrected|reversed|verified live|earlier draft|previously (said|claimed)|no longer (true|accurate)|now addressed|decisions logged|⚠|TODO|FIXME|XXX|HACK' <file>
   ```
   Expect no matches (or only deliberate, justified ones).

8. **Fresh-reader test.** Would someone with zero session history read this as one coherent current document — no contradictions, no "wait, which claim is right?", no visible edit scars? If not, fix what they'd trip on.

9. **Report.** State briefly what you pruned and what you re-verified (especially any claim that turned out stale and was corrected) — so the human knows the doc was reconciled, not just re-saved.

## Anti-patterns
- Trusting your own summary of the doc instead of re-reading it.
- "Fixing" only the section the user pointed at, leaving the same stale claim elsewhere.
- Replacing a wrong claim with a *new* unverified claim (verify the replacement too).
- Turning the doc into a changelog ("was X, now Y, corrected on Z") — that IS the scar.
