// l10n-allow-file: gallery and test fixture (an agent reply), not shipped UI.
// The reply Leo saw draw as raw pipe lines (2026-11-08, "whoa table broke rendering here?"): a GFM
// table written on the line right under a bold line, with no blank line between them. GFM lets a
// table interrupt a paragraph, so this is a bold line, then a table of 4 columns and 8 body rows.
export const TABLE_AFTER_BOLD_TABLE = `| Gap | Now | Target | Owner lane |
|---|---|---|---|
| Select to first reply (p50) | 45.4 s | ≤ 3 s | cloud-instant-start-v2 |
| Deploys with no passing end-to-end check | 193 in 24 h | 0 | goal-cloud-deploy-checked-2 |
| Merged fix running on a production machine | 29 min | ≤ 10 min | goal-cloud-fix-to-machine-2 |
| Machine time spent idle | 26% | ≤ 23% | cloud-machine-lifecycle |
| First turns that wait on a network fetch | every turn with a folder or repo (6 in 24 h) | none | goal-cloud-no-network-wait |
| New chat picks its environment on its own | failing | passing | goal-cloud-environment-auto-3 |
| Switching to SSH when the relay is down | failing | passing | cloud-backend-one-path |
| Classic \`/api/vm\` calls left in the Swift client | 27 | 0 | cloud-client-rust |`;

export const TABLE_AFTER_BOLD = `**What doesn't**
${TABLE_AFTER_BOLD_TABLE}

- **Unchecked deploys:** most are image rolls. Only 7 of 98 production cmux-vm deploys got a check.
- **Environment Auto:** its last test ran before tonight's 23:07Z platform deploy, so the next run is the one that counts.

Every goal has a live owner. The newest end-to-end Cloud chat run failed about 4 days ago and hasn't run since, so that signal is stale.`;
