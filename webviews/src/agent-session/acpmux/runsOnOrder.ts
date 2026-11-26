// Where a chat runs, in the one order every control that offers the choice lists it (cmux#57117):
// This Mac, Auto, Cloud. Auto sits between the two places it chooses from, so it reads as the step
// between them (cmux#51731). The composer's Where menu, Session Info's Runs On row, the Cloud
// toggle and the place control all read this list; the Where menu adds Other devices after it.

/// This Mac (`local`), Auto (`auto`), Cloud (`cloud`), top to bottom and left to right.
export const RUNS_ON_ORDER = ["local", "auto", "cloud"] as const;

export type RunsOnChoice = (typeof RUNS_ON_ORDER)[number];

/// Each choice's rows, in ``RUNS_ON_ORDER``: a choice with no rows is left out.
export function inRunsOnOrder<T>(rows: { readonly [K in RunsOnChoice]?: readonly T[] }): T[] {
  return RUNS_ON_ORDER.flatMap((choice) => rows[choice] ?? []);
}
