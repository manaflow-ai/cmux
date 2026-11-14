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
  one flush. The totals move by each change's difference. The list re-sorts (O(N log N), at most
  once a frame) only when an order key changed (an agent started or stopped waiting, the machine
  changed state), a machine came or went, or a change moved a row in or out of the filter; never on
  a cost tick.
- Events that arrive while the snapshot is read are held and applied over it once it lands; so is a
  Stop answer that comes during the read. A Stop answer is shown only when the stream sent nothing
  newer for that machine meanwhile.
- The list is windowed: every row is 52 px, only the rows in view and 8 above and below are in the
  DOM. Filter and search answer in the frame of the key press.
- A row opens its machine: the name is the row's button and covers the row. Stop takes the cost's
  cell while the row is hovered, focused or stopping, so the list has no column of repeated buttons.
  Every row and the column header share one track list, so the costs line up.
- No polling and no timers.

## Perf

`bun bench/board/run.ts` (webviews): a production build of the page, generated boards, headless
Chromium. "before" puts every row in the DOM (how the Cloud page lists machines); "after" is the
shipped page. Open is mount to the first painted frame with rows (median of 5); scroll is main-thread
work per one-screen step over 120 steps; live is 100 generated changes a second for 3 s.

| machines | mode   | open ms | rows in DOM | DOM nodes | scroll task ms/step | live task ms/s | live p95 frame ms |
| -------- | ------ | ------- | ----------- | --------- | ------------------- | -------------- | ----------------- |
| 3        | before | 29.9    | 3           | 144       | 0.12                | 35.9           | 16.8              |
| 3        | after  | 18.4    | 3           | 144       | 0.04                | 27.5           | 16.8              |
| 100      | before | 29.8    | 100         | 2,117     | 0.81                | 138.2          | 16.7              |
| 100      | after  | 17.3    | 24          | 567       | 3.17                | 57.8           | 16.8              |
| 1,000    | before | 154.8   | 1,000       | 19,735    | 10.38               | 574.3          | 66.6              |
| 1,000    | after  | 26.9    | 24          | 616       | 3.38                | 62.1           | 16.7              |
| 5,000    | before | 726     | 5,000       | 98,107    | 21.55               | 860.8          | 233.4             |
| 5,000    | after  | 26.5    | 24          | 616       | 2.78                | 49.7           | 16.7              |

Stated cost: a fast scroll mounts the rows coming into view, about 3 ms of work per one-screen
step at every size; at 100 machines that is more than with every row mounted (0.8 ms), at 5,000
it is an eighth of it.

## Dev loop

`cd webviews && bun run dev`, then `/board/?mock` (100 machines), `/board/?mock&machines=5000&rate=100`
(5,000 machines, 100 changes a second), `&seed=N` for another board. Gallery: `pages.board`.
