# Team: the team's agent spend, behind an experiment

History's Team tab (`webviews/src/agent-session/acpmux/teamAudit/`) shows the turns teammates share
with their team, summed by cmux-platform's `GET /v1/usage/audit`. It sits beside Costs
([ledger.md](ledger.md)), which shows this Mac's own spend. It shows only while the webviews
experiment `team-audit` is on, and that experiment ships off.

Leo, 2026-11-09: "for an engineering leader, it's easy to see like, oh wow, a cost auditing type
tracking tool baked into the thing. Like that's a super easy sell"

## Layout

- The top row is the same as Costs: a range (7, 30 or 90 days, whole UTC days ending today), a
  group-by (person, repository, model, agent, machine or day), and then Download CSV.
- The strip shows agent time first, then machine time (when the platform joins it), tokens in, cache
  reads, cache hit rate and turns.
- Then a table with one column per measure: tokens in (uncached input plus cache writes, as in Costs),
  tokens out, cache reads, cache writes, hit rate, turns, agent time and machine time. On a narrow pane
  it scrolls sideways.
- Turns whose agent did not report the field a grouping reads (an older client) show as "Not
  reported". Each person's own Mac shows as "local".
- Spend shows as time. There is no money column; the CSV keeps `costUsd` for anyone who wants it.

## States (gallery `agent-pane.team-audit`)

The gallery has a variant for each state:

- **Loaded:** a team admin's month.
- **By model:** grouped by model, including turns under "Not reported".
- **Not admin:** only the person's own turns, with a note saying so.
- **Empty:** sharing is on, but nothing was shared in the range.
- **Not shared:** the person is not in a team that shares usage.
- **Off:** the platform's audit is off for this team.
- **Signed out:** this Mac has no cmux sign-in.
- **Error:** the read failed, with Try again.
- **Older:** this Mac's acpmux has no `_acpmux/team_audit` yet.
- **Loading:** the first read is still on its way.

## Host and cost

- acpmux reads the platform with its own cmux sign-in (`meshRelay.tokenCommand`, the token the
  artifact tools use too). The token goes only to the relay's own origin. The page never holds a token.
- The relay allowlist (`AcpmuxPaneMethods` and `cmux-agent-pane-policy/policy.json`) lists
  `_acpmux/team_audit` with the params `since`, `until`, `groupBy` and `format`. The method is a read.
  With `format: csv` it writes one new file to Downloads; it never replaces an existing file.
- There is one read per range and grouping. The platform sums the turns in SQL, so a read costs the
  team's turns in the range, at most 180 days of them.
