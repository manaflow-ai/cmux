# Audit agent spend

See what every agent turn on this Mac cost, by session, workspace, repository, pull request, day, person, provider, or model.

The Costs tab in Agent History shows what every agent on this Mac spent, whichever agent ran it, grouped the way you choose.

## Where do I see what my agents cost?

Open the command palette, run Show Agent History, and pick the Costs tab. It reads the cost ledger of this Mac's agent daemon, which adds up each turn when the turn ends. So the tab opens at once, however many chats you have.

## What does the Costs tab show?

- A range: 24 hours, 7 days, 30 days, or all time.
- Totals for the range: cost, tokens in, tokens out, turns, tool calls, and agent time.
- One row per group, most spent first, with a bar for its share: cost, tokens in and out, turns, and agent time.
- Tokens in counts uncached input and cache writes. Cache reads are the same context sent again, so they are not counted.

## How do I group agent spend by repository, pull request, or person?

Pick a group: session, workspace, repository, pull request, day, person, provider, or model. cmux adds a session's pull requests as they open, so a pull request's row adds up every session that worked on it. Person is the user and machine that ran the agent.

## Where does each cost come from?

Each cost is marked with its source:

- Reported by the agent: the agent's own figure for the turn.
- Priced from the table: the turn's tokens at the price table that ships with cmux. The tab shows the table's version.
- Partly priced: a group whose turns had different sources, such as some reported and some from the table, or some with no price.
- No price known: no turn had a price, because the table does not list the model.

A turn with no price adds nothing to the cost. When the tab counts turns with no price, the cost shown for that range or group is incomplete: the real cost is at least that much.

A table price is an estimate at list prices, not a bill. On a subscription, the figure is what the same tokens would cost on the API, not what you pay. A fork's copy of its parent's turns counts once, in the parent.

## Can I read agent spend from the command line?

```bash
cmux acp ledger                              # the last 7 days, by repository
cmux acp ledger --since 30d --by pr          # the last 30 days, by pull request
cmux acp ledger --since 1d --by model --json # today, by model, as JSON
```

--by takes repo, pr, day, person, workspace, vendor, model, or account. --since takes a length such as 30m, 6h, or 7d.

## What does it cover?

Every turn that ran on this Mac's agent daemon, with any agent: Claude Code, Codex, or one you added. Each machine keeps its own ledger. Run cmux acp ledger on a machine to read that machine's.

- [Run agents on your own API keys](own-keys.md)
- [Plans and credits](plans.md)
- [Agents and subagents](agents.md)
