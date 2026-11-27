// l10n-allow-file: synthetic Chief task fixtures for the gallery and tests, not shipped copy.
import type { HomeRun, HomeRunChange, HomeRunStep } from "./types";

const run = (id: string, startedAt: number, steps: HomeRunStep[]): HomeRunChange => ({
  run: {
    id,
    conversation: "c1",
    author: "chief",
    status: "done",
    startedAt,
    endedAt: startedAt + 1_000,
    updatedAt: startedAt + 1_000,
    rev: 1,
    stepCount: steps.length,
    answers: [],
  } satisfies HomeRun,
  steps,
});

const step = (id: string, at: number, rest: Partial<HomeRunStep>): HomeRunStep => ({
  id,
  seq: at,
  at,
  rev: 1,
  kind: "note",
  attachments: [],
  links: [],
  ...rest,
});

/** A spawn of `tasks` at `at` whose answer gives each `- aN: <answer>`. */
export function spawnRun(id: string, at: number, tasks: [string, string, string][]): HomeRunChange {
  return run(id, at, [
    step(`${id}-spawn`, at, {
      kind: "tool",
      tool: {
        name: "mcp__optchat__spawn",
        input: { tasks: tasks.map(([, task]) => task) },
        output: tasks.map(([agent, , answer]) => `- ${agent}: ${answer}`).join("\n"),
        startedAt: at,
        files: [],
      },
    }),
  ]);
}

/** A note run at `at`: `[agent] text`. */
export function noteRun(id: string, at: number, agent: string, text: string): HomeRunChange {
  return run(id, at, [step(`report:${id}`, at, { text: `[${agent}] ${text}` })]);
}

export const HAT_NOW = 1_800_000_000_000;
const MIN = 60_000;

/** Two running tasks, one stalled, one just done, one stopped; and a workspace one the hat skips. */
export const hatRuns: HomeRunChange[] = [
  spawnRun("r1", HAT_NOW - 14 * MIN, [
    [
      "a1",
      "Title: Release notes lookup\nlook up the 0.63 notes",
      'hidden: a background task with no sidebar workspace (auto: the task mentions "look up")',
    ],
    [
      "a2",
      "Title: Hat variants\nMake 5 design variants",
      'workspace "Hat variants" in the cmux app on this Mac; shown because auto',
    ],
  ]),
  spawnRun("r2", HAT_NOW - 9 * MIN, [
    [
      "a3",
      "Title: Nightly status\ncheck the nightly",
      "hidden: a background task with no sidebar workspace (auto: a short task)",
    ],
    [
      "a4",
      "Title: Flake count\ncount flaky tests this week",
      "hidden: a background task with no sidebar workspace (auto: a short task)",
    ],
    [
      "a5",
      "Title: Benchmark soak\nrun the soak bench",
      "hidden: a background task with no sidebar workspace (you told me)",
    ],
  ]),
  noteRun("r3", HAT_NOW - 2 * MIN, "a1", "0.63 shipped the hat; notes are in RELEASE.md, three items."),
  noteRun("r4", HAT_NOW - MIN, "a4", "(stopped without a report: its session is cancelled)"),
  noteRun("r5", HAT_NOW - 30_000, "a5", "is stuck: no event for 15 min."),
];
