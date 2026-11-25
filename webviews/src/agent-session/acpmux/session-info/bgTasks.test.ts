// Issue #45951: an agent's daemon-owned background tasks (`acpmux bg start`) show in the chat while
// they run, as commands of the process registry: the running tray lists each with its command, its
// elapsed time, its output and Stop.
import { expect, test } from "bun:test";
import { trayItems } from "../subagents/runningTray";
import { BG_ENDED_KEPT, bgProcessId, bgTaskOf, bgTaskProcess, bgTaskProcesses } from "./bgTasks";
import { backgroundCommands, processesOf, mergeProcess } from "./processes";

const SESSION = "s1";
const task = (id: string, fields: Record<string, unknown> = {}) => ({
  id,
  sessionId: SESSION,
  command: `watch ${id}`,
  description: null,
  state: "running",
  startedAt: 1_000,
  endedAt: null,
  exitCode: null,
  tail: "",
  ...fields,
});

test("a task's process id names its chat and task, apart from a harness shell's", () => {
  const id = bgProcessId(SESSION, "bg-1a2b");
  expect(id).toBe("s1/bg:bg-1a2b");
  expect(bgTaskOf(id)).toEqual({ sessionId: SESSION, taskId: "bg-1a2b" });
  expect(bgTaskOf("s1/toolu_01")).toBeUndefined();
  expect(bgTaskOf("s1/bg:")).toBeUndefined();
});

test("a listed task reads as a registry process with its state, times and exit", () => {
  expect(bgTaskProcess(task("bg-a", { description: "  CI watcher " }))).toEqual({
    id: "s1/bg:bg-a",
    sessionId: SESSION,
    command: "watch bg-a",
    description: "CI watcher",
    state: "running",
    startedAt: 1_000,
    harness: "acpmux",
    origin: "acpmux_bg",
  });
  const state = (fields: Record<string, unknown>) => bgTaskProcess(task("bg-a", fields))?.state;
  expect(state({ state: "exited", exitCode: 0 })).toBe("exited");
  expect(state({ state: "exited", exitCode: 2 })).toBe("failed");
  expect(state({ state: "stopped" })).toBe("killed");
  expect(state({ state: "killed" })).toBe("killed");
  expect(state({ state: "lost" })).toBe("lost");
  expect(state({ state: "nonsense" })).toBeUndefined();
  expect(bgTaskProcess({ id: "x" })).toBeUndefined();
  expect(bgTaskProcess(task("bg-a", { state: "exited", exitCode: 1, endedAt: 9_000 }))).toMatchObject({
    endedAt: 9_000,
    exitCode: 1,
  });
});

test("a listing keeps every running task and only the latest ended ones", () => {
  const ended = Array.from({ length: BG_ENDED_KEPT + 5 }, (_, i) =>
    task(`bg-e${i}`, { state: "exited", exitCode: 0, startedAt: 10 + i }),
  );
  const records = bgTaskProcesses({ tasks: [task("bg-run", { startedAt: 1 }), ...ended, { junk: true }] });
  expect(records).toHaveLength(BG_ENDED_KEPT + 1);
  expect(records[0]!.id).toBe("s1/bg:bg-run");
  expect(records[1]!.id).toBe("s1/bg:bg-e5");
  expect(bgTaskProcesses(undefined)).toEqual([]);
});

test("a running task is a tray line between turns, with Stop, and leaves it when it ends", () => {
  const listed = processesOf({ processes: bgTaskProcesses({ tasks: [task("bg-a"), task("bg-b")] }) }, SESSION);
  const commands = backgroundCommands(listed, [], true);
  expect(commands.map((command) => [command.command, command.state, command.processId, command.startedAt])).toEqual([
    ["watch bg-a", "running", "s1/bg:bg-a", 1_000],
    ["watch bg-b", "running", "s1/bg:bg-b", 1_000],
  ]);
  // No turn runs: a registry command still shows, so both watchers do.
  expect(trayItems([], commands, [], false).map((item) => item.id)).toEqual(["s1/bg:bg-a", "s1/bg:bg-b"]);
  // Its `bg_update` end, as direct.ts hands it to the registry's listeners.
  const after = mergeProcess(listed, bgTaskProcess(task("bg-a", { state: "stopped", endedAt: 5_000 })), SESSION);
  const now = backgroundCommands(after, [], true);
  expect(now.find((command) => command.id === "s1/bg:bg-a")).toMatchObject({ state: "stopped", endedAt: 5_000 });
  expect(trayItems([], now, [], false).map((item) => item.id)).toEqual(["s1/bg:bg-b"]);
});
