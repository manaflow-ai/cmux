# Goals in cmux NEXT

cmux NEXT shows a conversation's unresolved work as a compact strip above the
Home/Chief timeline, so the user can see what the Chief is doing without
reading run cards. This doc describes what shipped in #21254 and #21277 and
lists the work that is still open.

## What landed

`webviews/src/pages/home-channels/goal.ts` defines a view-only projection:

```ts
type HomeGoalState = "working" | "stalled" | "failed";

interface HomeGoal {
  run: HomeRun;
  state: HomeGoalState;
  title: string;
  detail?: string;
}
```

There is no owner-side goal record. The goal is derived from the run book:
`GoalStrip` hands the entry `RunBook.goalEntry` picks to `projectGoal(entries,
now)`, which projects the first running or failed entry it is given.

- `RunBook.goalEntry(conversation)` picks the newest run (by `updatedAt`) in
  the conversation whose status is `running` or `failed`.
- A `running` run is `working`, or `stalled` once `isStale` in `runs.ts` holds
  (no update for `STALE_RUN_MS`, 30 minutes). Runs with `updatedAt` 0 never
  go stale.
- A `failed` run is `failed`, and `detail` carries `run.error`.
- `done` and other ended runs never project a goal and never replace one.
  The strip disappears only once no running or failed run is left in the
  conversation, so an older failed or stalled run stays on the strip even
  after later work completes.
- `title` is `run.title` only. `answers` holds message IDs, not display text,
  so it is never used as a title (#21277). An empty title falls back to the
  localized `run.title` label in the view.

`GoalStrip.tsx` renders the projection. `HomeChannelsPage` mounts it at the
top of `.lg-stage`, directly above `Timeline`, with the run book, the open
conversation id, and `runs.onOpen`. The strip:

- is an `<output>` with `aria-live="polite"`, `aria-label` set to the title,
  and `aria-busy` while working;
- shows the shared `RunMark`, the localized state (`run.status.running`,
  `run.status.stale`, `run.status.failed`), the title, and the error detail
  when present;
- has one action, `run.open`, which opens the run sheet for the goal's run;
- ticks its clock once a second (`useNow`) only while the run is running, so
  the stalled transition shows without a new owner event;
- colors failed and stalled states in `ledger.css`, fades between states over
  180 ms, and turns the transition off under `prefers-reduced-motion`.

`webviews/test/goal-strip.test.ts` covers the working, stalled, failed, and
completed projections and the answer-ID title case. The gallery lists
`GoalStrip` as a source but has no goal-specific variants yet.

## Codex thread goals

The Codex chat pane also shows the thread goal Codex persists, independently of the Home run
projection above. The in-process bridge restores it with `thread/goal/get` and forwards goal
updates and clearing. acpmux keeps the latest projection in optional session metadata, and the
pane reads that state on attach before applying later events. Older metadata and clients remain
valid; there is no storage migration.

`TaskGoalStrip` keeps the objective and state visible between turns and after reopening. Pause,
Resume and Clear use `/goal` through the normal session send path. The slash menu is shared with
New Tab; typing a slash lazily prepares a deferred chat to read the harness's actual commands.
Codex remains the owner of goal continuation and token budgets. A normal message during a goal's
autonomous turn steers that turn; an explicit busy refusal caused by a continuation winning the
send race reads the current turn once and steers the original input.

## Open work (proposals)

These are not built. Each should land as its own PR.

1. **Owner goal record.** The goal is inferred from the newest unresolved
   run, so a new run replaces the previous goal and a stalled or failed state
   is computed per client. If the daemon starts owning goals, add an optional
   projection to the Home conversation snapshot and the owner event stream,
   persist the `stalled` transition there so every client agrees, and keep
   `HomeRun` as the execution record a goal points at. When that lands, the
   view-only `HomeGoal` should take the owner shape instead of a second type
   being added beside it, and the run-derived projection becomes the
   fallback for owners that do not emit goals.
2. **More states.** `waiting` (blocked on the user) and `completed` (briefly
   shown, then moved to history) need an owner signal; the run status alone
   cannot tell them apart.
3. **Dismiss and retry.** A failed goal stays until a newer running or failed
   run replaces it; a later completed run does not clear it.
   There is no dismiss or retry action on the strip yet.
4. **Disclosure.** The strip is a single line. A collapsed disclosure for
   progress and recent blockers, using the agent-chat disclosure motion, is
   still to do; keyboard focus would then land on the disclosure before the
   primary action.
5. **Gallery fixtures.** Add home-channels gallery variants for working,
   stalled, and failed strips, including a reduced-motion check.

Goal creation, editing, and cross-conversation goal management come after the
owner record exists.
