import { expect, test } from "bun:test";
import { chiefTasks, HAT_TTL_MS, nextExpiry } from "../src/pages/home-channels/chiefTasks";
import { HAT_NOW, hatRuns, noteRun, spawnRun } from "../src/pages/home-channels/chiefTasksFixtures";
import { RunBook } from "../src/pages/home-channels/runs";
import type { HomeRunChange } from "../src/pages/home-channels/types";

const tasksOf = (runs: HomeRunChange[], now = HAT_NOW) => {
  const book = new RunBook();
  book.apply(runs);
  return chiefTasks(book.entriesOf("c1"), now);
};

test("background tasks show as rows; a workspace subagent does not", () => {
  const tasks = tasksOf(hatRuns);
  expect(tasks.map((t) => [t.id, t.state])).toEqual([
    ["a3", "running"],
    ["a5", "stalled"],
    ["a4", "stopped"],
    ["a1", "done"],
  ]);
  expect(tasks.find((t) => t.id === "a1")).toMatchObject({
    title: "Release notes lookup",
    result: "0.63 shipped the hat; notes are in RELEASE.md, three items.",
  });
  expect(tasks.some((t) => t.id === "a2")).toBe(false);
});

test("a finished task expires from the hat; running ones stay; nothing is prodded", () => {
  const later = HAT_NOW + HAT_TTL_MS;
  expect(tasksOf(hatRuns, later).map((t) => t.id)).toEqual(["a3", "a5"]);
  const now = tasksOf(hatRuns);
  expect(nextExpiry(now)).toBe(HAT_NOW - 2 * 60_000 + HAT_TTL_MS);
  expect(nextExpiry(tasksOf(hatRuns, later))).toBeUndefined();
});

test("a stall marks a task once and its report still ends it", () => {
  const runs = [
    spawnRun("s", HAT_NOW - 60_000, [["a9", "count tests", "hidden: no sidebar workspace (auto: a short task)"]]),
    noteRun("n1", HAT_NOW - 50_000, "a9", "is stuck: no event for 15 min."),
    noteRun("n2", HAT_NOW - 40_000, "a9", "Counted 12 flaky tests.\nDetails follow."),
  ];
  expect(tasksOf(runs)).toEqual([
    { id: "a9", title: "count tests", state: "done", startedAt: HAT_NOW - 60_000, endedAt: HAT_NOW - 40_000, result: "Counted 12 flaky tests." },
  ]);
});
