# Goals in cmux NEXT

cmux NEXT should make an agent's current goal visible without turning every run
into a wall of status text. The goal is a compact, dismissible strip above the
Home/Chief conversation, with the detailed run history still available below.

## User-facing behavior

When a conversation has an active goal, the strip shows:

- a short goal title and the full objective in an accessible label;
- the current state: `Working`, `Waiting`, `Stalled`, `Completed`, or `Failed`;
- the latest meaningful update time;
- one primary action: resume the conversation, open the relevant run, or
  reopen the goal details;
- a disclosure affordance for progress and recent blockers.

The default view is quiet. The strip stays one line tall when healthy, and the
progress disclosure is collapsed. A stalled goal remains visible after the
agent run ages out so the user can see why the Chief stopped looking active.
Completed goals move into the conversation history and do not keep a live
banner. Failed goals keep the error summary and the retry action until the
user dismisses or retries them.

The strip uses the same measured disclosure motion as agent-chat history and
respects `prefers-reduced-motion`. A state change changes color and icon with a
short fade; it must not move the timeline or steal focus. Keyboard focus lands
on the strip's disclosure button, then the primary action.

## Data ownership

The daemon remains the source of truth. Add an optional goal projection to the
Home conversation snapshot rather than deriving it from rendered text:

```ts
interface HomeGoal {
  id: string;
  title: string;
  objective: string;
  state: "working" | "waiting" | "stalled" | "completed" | "failed";
  updatedAt: number;
  blocker?: string;
  runId?: string;
  conversation: string;
}
```

`HomeRun` remains the detailed execution record. A goal may reference the
current run, but a missing or stale run must not erase the goal. The existing
`isStale` rule in `webviews/src/pages/home-channels/runs.ts` supplies the
initial `stalled` transition; the owner persists the resulting state so every
client agrees about whether the goal is still active.

The webview receives goal changes through the same owner event stream as
conversation and run changes. It keeps a bounded goal book keyed by
`conversation + goal.id`, applies revision ordering, and clears only goals
for conversations the owner explicitly removed.

## Rendering seam

`HomeChannelsPage` should render a `GoalStrip` immediately above the timeline
when the selected conversation has an active or recently failed goal. The
strip gets the selected conversation, its goal projection, the matching
`RunEntry`, and the existing `RunsContextValue` actions. It must not reach into
the run store directly or duplicate the run-state reducer.

`GoalStrip` should reuse the existing status mark, `RunSheet`, and `RunCard`
language. The first implementation can use the current run title as a
fallback title while the daemon starts emitting the explicit `HomeGoal`
projection; it must label that fallback as inferred and never persist it as a
goal.

## Acceptance criteria

- A long-running goal remains visible while its run card folds or virtualizes.
- A stale run changes the strip to `Stalled` without making the whole Chief
  appear active.
- Starting a new run for the same goal returns it to `Working` and clears the
  old blocker only after the owner acknowledges the new run.
- Reloading the Home page preserves the goal state and disclosure state is
  reset per conversation.
- VoiceOver can announce the goal title, state, blocker, and primary action.
- The strip has gallery fixtures for working, stalled, failed, and completed
  states, including reduced-motion coverage.

This is intentionally a projection and rendering seam first. Goal creation,
editing, and cross-conversation goal management should follow after the
read-only strip has stable owner events and accessibility coverage.
