// l10n-allow-file: test fixture prompts and host words, not shipped UI.
// The quiet Cloud start line (cloudStartViewModel `quietStage`): the stage a start is on, why the chat
// waits and about how long, from the same rows the startup checklist shows.
import { expect, test } from "bun:test";
import type { CloudStartProgress } from "./cloudStartProgress";
import { quietStage, startupChecklist } from "./cloudStartViewModel";

const base: CloudStartProgress = { key: "k", task: "fix the build", state: "starting", folder: "paint" };
const stage = (start: CloudStartProgress) => quietStage(start, startupChecklist(start, undefined, 20_000, "en"));

test("a start just sent is starting its machine, usually under a minute", () => {
  expect(stage(base)).toEqual({
    id: "machine",
    label: "Starting your Cloud machine",
    eta: "usually under a minute",
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
    eta: "usually under a minute",
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
    eta: "1,200 of 3,000 files",
    since: 12_000,
  });
});

test("setup counts only once the host reports it, and a cached snapshot is quick", () => {
  const cloned = { ...base, hasRepository: true, clone: { state: "done" } } as const;
  // No setup reported: the next stage is the agent's.
  expect(stage({ ...cloned, agent: "Claude Code" })).toMatchObject({
    id: "harness",
    label: "Starting Claude Code",
    eta: "usually a few seconds",
    step: 3,
    steps: 3,
  });
  expect(stage({ ...cloned, setup: { state: "running", status: "building", startedAt: 15_000 } })).toEqual({
    id: "setup",
    label: "Running your setup script",
    eta: "a few minutes the first time",
    since: 15_000,
    step: 3,
    steps: 4,
  });
  expect(stage({ ...cloned, setup: { state: "running", status: "ready" } })?.eta).toBe("usually a few seconds");
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
