# Costs: what the agents spent, by any grouping

The agent pane's History screen has a Costs tab (`webviews/src/agent-session/acpmux/ledger/`,
`LedgerScreen.tsx`). It reads acpmux's `_acpmux/ledger` for one range and shows every vendor's
spend in one place: cost, tokens, turns, tool calls and agent time, grouped the way the person
asks. It is shared web inside an existing host (the History screen), so it needs no new Swift.

Leo: "We should just make the best thing we can; any namedropped references to other
companies/projects should typically just stay internal. We should defo build ALL of these things tho."

## References

- A usage-status panel: one strip of totals over a ranked list, with each row's share drawn as a
  quiet fill and not as a chart.
- A billing breakdown: a group-by switch over the same rows, and each amount marked with where
  it came from.

## Layout

- The controls row: the range (24h, 7d, 30d, All) as a segmented control, then Group by
  (Session, Workspace, Repository, Pull request, Day, Person, Provider, Model) as a select.
- The strip: six tiles on one tonal fill (Cost, Tokens in, Tokens out, Turns, Tool calls, Agent
  time). Numbers are compact and tabular, and the labels are captions.
- The note line: the price table's version (small, tertiary ink), how many turns had no price,
  and a legend for the cost-source marks.
- Rows: label and detail on the left, cost on the right with its source mark. The share against
  the largest row is a tonal fill behind the row (`transform: scaleX`, so it never causes layout).
- There are no borders anywhere: tonal fills only.

## Cost sources

| Mark | Meaning |
| --- | --- |
| none | Reported by the agent: every turn's cost came from the agent itself |
| hollow dot | Priced from the table: cmux's price table (its version is on the note line) |
| half dot | Partly priced: partly reported and partly priced, or some turns had no price (the cost is a floor) |
| dash | No price known: tokens and turns are shown, the cost is zero |

## Row states

| State | Start | End |
| --- | --- | --- |
| Range or group changes | the old rows | the new rows, with bars moving from their old share to the new one on the house curve |
| Session row: pointer or focus | the tonal fill | one step stronger; Return or a click opens that chat in this tab, as History's own rows do (`chat.select`) |
| Loading | dashes in the strip, no rows | the numbers, in place: the strip never changes height |
| Older acpmux (`method not found`, or the relay does not list it) | — | "This Mac's agent service is older and keeps no cost ledger yet. Update cmux to see costs here." No error tone |
| Failed | — | the reason and Try again |

## Variants (gallery `agent-pane.costs`) and the pick

1. `bars`: the share is a tonal fill behind the row, and the cost sits at the end.
2. `table`: one column per measure, and the share is a thin line under the row.
3. `stacked`: two-line labels, with the share bar beneath.

Shipped: `bars`. It reads in one glance at 380 px, the ranking is the fill itself, and it uses
no extra row height. `table` stops fitting below about 600 px, and `stacked` doubles the row
height for no new information. The gallery also covers by-repo, by-day, 2,000 sessions, loading,
empty and older.

## Host and cost

- The page is a tab of the History screen, which is already reached from the agent pane's History
  action. There is no new page provider and no Swift view.
- The relay allowlist (`AcpmuxPaneMethods`, and `cmux-agent-pane-policy/policy.json`) lists
  `_acpmux/ledger` with the params `since`, `until`, `limit` and `groupBy`. All of them are read-only.
- One read per range: every rollup comes back in it, so switching the group never reads again.
- The list is windowed (`ui/VirtualList`), so a frame draws only the visible rows, whatever the
  number of sessions. Rows are memoized, so switching the group recomputes one sort.
