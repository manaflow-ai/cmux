// A New Tab `!command` runs in the chat's shell block (#17541), so the output and
// removable command chip stay with that chat. Opening a terminal is a separate action.
import { expect, test } from "bun:test";
import { newTabScreenActions } from "../src/agent-session/acpmux/newtab/screenActions";
import { ShellRuns } from "../src/agent-session/acpmux/shell/shellRuns";

test("New Tab shell mode runs in the chat and preserves its command result", async () => {
  const calls: [string, Record<string, unknown> | undefined][] = [];
  const runner = new ShellRuns(async <T>(method: string, params?: Record<string, unknown>): Promise<T> => {
    calls.push([method, params]);
    if (method === "shell.run") return { id: "host-run" } as T;
    if (method === "shell.read") return { output: "/repo\n", next: 6, exit: { code: 0 } } as T;
    throw new Error(`unexpected host request: ${method}`);
  });
  let leaves = 0;
  const actions = newTabScreenActions({
    callNative: (method) => {
      throw new Error(`New Tab should not open another surface: ${method}`);
    },
    cwd: "/repo",
    leave: () => {
      leaves += 1;
    },
    selectSession: () => {},
    showAllChats: () => {},
    runShell: (command, cwd) => {
      runner.start(command, cwd ? { cwd } : {});
    },
  });

  actions.onShell("pwd");
  expect(leaves).toBe(1);
  expect(runner.snapshot()).toMatchObject([{ command: "pwd", cwd: "/repo", status: "running" }]);
  for (let step = 0; step < 4; step += 1) await Promise.resolve();
  expect(calls).toEqual([
    ["shell.run", { command: "pwd", cwd: "/repo" }],
    ["shell.read", { id: "host-run", after: 0 }],
  ]);
  expect(runner.snapshot()).toMatchObject([
    { command: "pwd", cwd: "/repo", status: "done", exitCode: 0, output: "/repo\n" },
  ]);
});

test("New Tab shell mode leaves folder selection to the chat when no folder was inherited", () => {
  const runs: [string, string | undefined][] = [];
  let leaves = 0;
  const actions = newTabScreenActions({
    callNative: (method) => {
      throw new Error(`unexpected host request: ${method}`);
    },
    leave: () => {
      leaves += 1;
    },
    selectSession: () => {},
    showAllChats: () => {},
    runShell: (command, cwd) => {
      runs.push([command, cwd]);
    },
  });

  actions.onShell("echo hello");
  expect(leaves).toBe(1);
  expect(runs).toEqual([["echo hello", undefined]]);
});
