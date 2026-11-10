import { expect, test } from "bun:test";
import { chiefTasks, HAT_TTL_MS, nextExpiry, TASK_GONE_MS, TASK_STALL_MS } from "../src/pages/home-channels/chiefTasks";
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
    {
      id: "a9",
      title: "count tests",
      state: "done",
      startedAt: HAT_NOW - 60_000,
      endedAt: HAT_NOW - 40_000,
      result: "Counted 12 flaky tests.",
    },
  ]);
});

test("a cancel the Chief sends ends the row; one never heard of stalls, then leaves", () => {
  const start = HAT_NOW - 60_000;
  const spawn = spawnRun("s", start, [
    ["a7", "count tests", "hidden: a background task with no sidebar workspace (auto)"],
  ]);
  const cancel = spawnRun("c", HAT_NOW - 30_000, []);
  cancel.steps.push({
    id: "c-control",
    seq: 1,
    at: HAT_NOW - 30_000,
    rev: 1,
    kind: "tool",
    attachments: [],
    links: [],
    tool: { name: "mcp__optchat__control", input: { action: "cancel", id: "a7" }, files: [] },
  });
  expect(tasksOf([spawn, cancel]).map((t) => t.state)).toEqual(["stopped"]);
  expect(tasksOf([spawn], start + TASK_STALL_MS).map((t) => t.state)).toEqual(["stalled"]);
  expect(tasksOf([spawn], start + TASK_GONE_MS)).toEqual([]);
});

test("each Chief's a1 is its own task", () => {
  const mine = spawnRun("m", HAT_NOW - 60_000, [["a1", "Title: Mine\nx", "hidden: a background task"]]);
  const theirs = spawnRun("t", HAT_NOW - 50_000, [["a1", "Title: Theirs\ny", "hidden: a background task"]]);
  theirs.run = { ...theirs.run, author: "chief-2" };
  const report = noteRun("r", HAT_NOW - 10_000, "a1", "done");
  expect(tasksOf([mine, theirs, report]).map((t) => [t.title, t.state])).toEqual([
    ["Theirs", "running"],
    ["Mine", "done"],
  ]);
});
