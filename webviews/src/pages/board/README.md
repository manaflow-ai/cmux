# Team board (`cmux-page://cmux.board/`)

One screen with every machine and agent of a team: who started it, what it is doing, whether an
agent waits on a person, what it has cost, with Stop and Open.

## Data

The board is fed by three answers the platform already gives (cmux-platform `src/api/Machines.ts`):

| Answer                   | What the board takes from it                                                  |
| ------------------------ | ----------------------------------------------------------------------------- |
| `GET /v1/machines`       | Every machine: state, creator, cost so far and rate, who is on it, its error. |
| `GET /v1/machines/usage` | Cost by machine, used when a list record carries no cost.                     |
| `GET /v1/machines/audit` | The newest action on each machine and who did it (a person or an agent).      |

The host answers `cmux.board.snapshot` with the three answers untouched, plus the team's members and
each machine's agent sessions when it knows them, and streams `cmux.board.changes` (types.ts
`BoardEvent`). `cmux.board.stop` pauses a machine; `cmux.board.open` opens it in this app. The page
joins the answers itself (model.ts) and trusts no number: a cost that is missing, negative,
non-finite or a string shows a dash and counts under "Cost unknown", never in the totals. A creator
the member list does not hold shows as not on the team and counts under "No owner".

Host gap: no host serves `cmux.board.*` yet; the page says "not available in this build" until one
does. The dev loop and the gallery use the mock host (mockProvider.ts).

## Files

| File              | Role                                                                                  |
| ----------------- | ------------------------------------------------------------------------------------- |
| `types.ts`        | Op names and the wire shapes of the three answers.                                    |
| `model.ts`        | Pure join, owners, sane costs, totals (added and taken away per row), order, filter.  |
| `store.ts`        | Keyed rows (`subscribeRow`), one published flush per frame, Stop and Open.            |
| `BoardPage.tsx`   | Header, totals, filters, search, and the windowed list.                               |
| `fixtures.ts`     | Seeded generated boards with the degenerate cases, and a stream of generated changes. |
| `mockProvider.ts` | In-memory host for the dev loop, the gallery, the tests and the perf harness.         |

## Rules the page keeps

- A row reads only its own record (`useSyncExternalStore` on its id). A change to one machine
  re-renders that row, not the list.
- Changes land in the store at once and are published once per frame: 100 changes in a frame cost
  one flush. The totals move by each change's difference. The list re-sorts only when an order key
  changed (an agent started or stopped waiting, the machine changed state), never on a cost tick.
- The list is windowed: every row is 52 px, only the rows in view and 8 above and below are in the
  DOM. Filter and search answer in the frame of the key press.
- No polling and no timers.

## Perf

`bun bench/board/run.ts` (webviews): a production build of the page, generated boards, headless
Chromium. "before" puts every row in the DOM (how the Cloud page lists machines); "after" is the
shipped page. Open is mount to the first painted frame with rows (median of 3); scroll is main-thread
work per one-screen step over 120 steps; live is 100 generated changes a second for 3 s.

| machines | mode   | open ms | rows in DOM | DOM nodes | scroll task ms/step | live task ms/s | live p95 frame ms |
| -------- | ------ | ------- | ----------- | --------- | ------------------- | -------------- | ----------------- |
| 3        | before | 27.7    | 3           | 146       | 0.04                | 30.2           | 16.7              |
| 3        | after  | 17.4    | 3           | 146       | 0.04                | 37.7           | 16.7              |
| 100      | before | 31.2    | 100         | 2,147     | 0.85                | 184.7          | 16.8              |
| 100      | after  | 17.5    | 24          | 578       | 2.95                | 57.2           | 16.7              |
| 1,000    | before | 136.8   | 1,000       | 20,107    | 7.58                | 485.9          | 33.4              |
| 1,000    | after  | 30.0    | 24          | 617       | 3.96                | 45.2           | 16.7              |
| 5,000    | before | 700.7   | 5,000       | 99,963    | 18.2                | 834.9          | 183.3             |
| 5,000    | after  | 26.0    | 24          | 617       | 3.51                | 75.9           | 16.8              |

## Dev loop

`cd webviews && bun run dev`, then `/board/?mock` (100 machines), `/board/?mock&machines=5000&rate=100`
(5,000 machines, 100 changes a second), `&seed=N` for another board. Gallery: `pages.board`.
