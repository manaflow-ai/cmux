// l10n-allow-file: test fixture prompts and host words, not shipped UI.
// The quiet Cloud start line (cloudStartViewModel `quietStage`): the stage a start is on, why the chat
// waits and its live clock (never a usual wait), from the same rows the startup checklist shows.
import { expect, test } from "bun:test";
import type { CloudStartProgress } from "./cloudStartProgress";
import { quietStage, stageClock, startupChecklist } from "./cloudStartViewModel";

const base: CloudStartProgress = { key: "k", task: "fix the build", state: "starting", folder: "paint" };
const stage = (start: CloudStartProgress) => quietStage(start, startupChecklist(start, undefined, 20_000, "en"));

test("a start just sent is starting its machine, with no usual-wait hint", () => {
  expect(stage(base)).toEqual({
    id: "machine",
    label: "Starting your Cloud machine",
    step: 1,
    steps: 3,
  });
  // The host's older `step` says the same, and a known start time gives the line its clock.
  expect(stage({ ...base, step: "machine", machineStartedAt: 10_000 })).toMatchObject({
    id: "machine",
    since: 10_000,
  });
});

test("the copy stage says the copy's own progress when the host reports it", () => {
  const copying = { ...base, step: "folder" } as const;
  expect(stage(copying)).toMatchObject({
    id: "clone",
    label: "Copying your project",
    step: 2,
  });
  const clone = {
    state: "running",
    startedAt: 12_000,
    phase: "copy",
    progress: { filesDone: 1200, filesTotal: 3000 },
  } as const;
  expect(stage({ ...base, hasRepository: true, machineFinishedAt: 12_000, clone })).toMatchObject({
    id: "clone",
    detail: "1,200 of 3,000 files",
    since: 12_000,
  });
});

test("a GitHub repository's start says it clones from GitHub, never that it copies the project (cmux#53226)", () => {
  const cloning = { ...base, step: "folder", cwd: "github:manaflow-ai/cmuxterm-hq", folder: "cmuxterm-hq" } as const;
  expect(stage(cloning)).toMatchObject({ id: "clone", label: "Cloning from GitHub" });
  // A folder of this Mac is still copied.
  expect(stage({ ...base, step: "folder", cwd: "/Users/dev/paint" })).toMatchObject({ label: "Copying your project" });
});

test("setup counts only once the host reports it, and a cached snapshot is quick", () => {
  const cloned = { ...base, hasRepository: true, clone: { state: "done" } } as const;
  // No setup reported: the next stage is the agent's.
  expect(stage({ ...cloned, agent: "Claude Code" })).toMatchObject({
    id: "harness",
    label: "Starting Claude Code",
    step: 3,
    steps: 3,
  });
  expect(stage({ ...cloned, setup: { state: "running", status: "building", startedAt: 15_000 } })).toEqual({
    id: "setup",
    label: "Running your setup script",
    since: 15_000,
    step: 3,
    steps: 4,
  });
  expect(stage({ ...cloned, setup: { state: "running", status: "ready" } })).not.toHaveProperty("detail");
  // A start with no setup script skips it: the agent's stage is next.
  expect(stage({ ...cloned, setup: { state: "skipped", hasScript: false } })?.id).toBe("harness");
});

test("a start with no project skips the copy", () => {
  const home = { key: "k", task: "hi", state: "starting", home: true, step: "opening", agent: "Codex" } as const;
  expect(stage(home)).toMatchObject({ id: "harness", label: "Starting Codex", step: 2, steps: 2 });
});

test("no stage once the agent has started or the start failed", () => {
  expect(stage({ ...base, initialized: true })).toBeUndefined();
  expect(stage({ ...base, state: "failed", message: "no machine" })).toBeUndefined();
});

test("a step's clock reads whole seconds under a minute, then m:ss, then h:mm:ss, never ahead of time", () => {
  expect(stageClock(0)).toBe("0s");
  expect(stageClock(999)).toBe("0s");
  expect(stageClock(12_400)).toBe("12s");
  expect(stageClock(59_999)).toBe("59s");
  expect(stageClock(60_000)).toBe("1:00");
  expect(stageClock(65_000)).toBe("1:05");
  expect(stageClock(10 * 60_000 + 9_000)).toBe("10:09");
  expect(stageClock(3_723_000)).toBe("1:02:03");
  expect(stageClock(-5)).toBe("0s");
});

test("no stage ever carries a usual-wait hint, and only a running copy carries its progress", () => {
  const starts: CloudStartProgress[] = [
    base,
    { ...base, step: "machine" },
    { ...base, step: "folder" },
    { ...base, hasRepository: true, clone: { state: "running", phase: "clone" } },
    { ...base, hasRepository: true, clone: { state: "done" }, setup: { state: "running", status: "building" } },
    { ...base, hasRepository: true, clone: { state: "done" }, setup: { state: "running", status: "ready" } },
    { ...base, hasRepository: true, clone: { state: "done" }, step: "opening", agent: "Codex" },
  ];
  for (const start of starts) {
    const line = stage(start);
    expect(line).toBeDefined();
    expect(JSON.stringify(line)).not.toMatch(/usually|first time|"eta"/i);
    if (line?.id !== "clone") expect(line).not.toHaveProperty("detail");
  }
});

test("the checklist rows' durations use the same clock: seconds, then m:ss", () => {
  const rows = startupChecklist(
    {
      ...base,
      hasRepository: true,
      machineStartedAt: 0,
      machineFinishedAt: 400,
      clone: { state: "done", startedAt: 1_000, finishedAt: 76_000 },
      setup: { state: "running", status: "building", startedAt: 76_000 },
    },
    undefined,
    88_500,
    "en",
  );
  expect(rows.map((row) => [row.id, row.duration])).toEqual([
    ["machine", "<1s"],
    ["clone", "1:15"],
    ["setup", "12s"],
    ["harness", undefined],
  ]);
});

test("a machine waking from a pause or a resume says Waking machine, on its row and as the stage", () => {
  const waking = { ...base, step: "machine", waking: true } as const;
  const rows = startupChecklist(waking, undefined, 20_000, "en");
  expect(rows[0]).toMatchObject({ id: "machine", status: "running", detail: "Waking machine" });
  expect(stage(waking)).toMatchObject({ id: "machine", label: "Waking machine" });
  // Once the machine is up the row is done and says nothing of waking.
  const up = startupChecklist({ ...waking, step: "folder" }, undefined, 20_000, "en");
  expect(up[0].detail).toBeUndefined();
  expect(stage({ ...base, step: "machine" })).toMatchObject({ label: "Starting your Cloud machine" });
});
