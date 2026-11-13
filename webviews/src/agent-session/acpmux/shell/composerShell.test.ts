import { expect, test } from "bun:test";
import { ShellRuns, composerShell } from "./shellRuns";

/// A Cloud chat's composer has shell mode, as a local chat's does (Leo, cmuxterm-hq#7856:
/// "whatever works on a local chat should work on a Cloud chat"). Its command goes to the host with
/// the chat's folder as the chat's machine names it; the host runs it on that machine.
type Call = { method: string; params?: Record<string, unknown> };

function host(reads: Array<Record<string, unknown>>) {
  const calls: Call[] = [];
  const native = async <T>(method: string, params?: Record<string, unknown>): Promise<T> => {
    calls.push({ method, ...(params ? { params } : {}) });
    if (method === "shell.run") return { id: "run_1" } as T;
    if (method === "shell.read") return (reads.shift() ?? { output: "", next: 0, exit: { code: 0 } }) as T;
    return undefined as T;
  };
  return { calls, native };
}

async function settled(runs: ShellRuns, id: string) {
  for (let turn = 0; turn < 50 && runs.get(id)?.status === "running"; turn += 1) {
    await new Promise<void>((resolve) => setTimeout(resolve, 0));
  }
  return runs.get(id);
}

test("a Cloud chat's command goes to the host with the chat's folder on its machine", async () => {
  const { calls, native } = host([
    { output: "/home/cmux/chats/project\n", next: 25 },
    { output: "", next: 25, exit: { code: 0 } },
  ]);
  const runs = new ShellRuns(native);
  const onShell = composerShell(runs, { cwd: "/home/cmux/chats/project", sessionId: "s_cloud" });
  expect(typeof onShell).toBe("function");
  const run = onShell("pwd");
  expect(run.sessionId).toBe("s_cloud");
  const done = await settled(runs, run.id);
  expect(calls[0]).toEqual({ method: "shell.run", params: { command: "pwd", cwd: "/home/cmux/chats/project" } });
  expect(calls.slice(1).map((call) => [call.method, call.params?.id, call.params?.after])).toEqual([
    ["shell.read", "run_1", 0],
    ["shell.read", "run_1", 25],
  ]);
  expect(done?.status).toBe("done");
  expect(done?.output).toBe("/home/cmux/chats/project\n");
  expect(runs.forSession("s_cloud").map((each) => each.id)).toEqual([run.id]);
});

test("a chat with no folder yet leaves the folder to the host", async () => {
  const { calls, native } = host([]);
  const runs = new ShellRuns(native);
  const run = composerShell(runs, {})("ls");
  await settled(runs, run.id);
  expect(calls[0]).toEqual({ method: "shell.run", params: { command: "ls" } });
});

test("the machine's refusal shows on the block", async () => {
  const calls: Call[] = [];
  const runs = new ShellRuns(async <T>(method: string, params?: Record<string, unknown>): Promise<T> => {
    calls.push({ method, ...(params ? { params } : {}) });
    throw new Error("Too many commands running");
  });
  const run = composerShell(runs, { cwd: "/home/cmux/chats/project" })("sleep 9");
  const done = await settled(runs, run.id);
  expect(done?.status).toBe("failed");
  expect(done?.error).toBe("Too many commands running");
  expect(calls.map((call) => call.method)).toEqual(["shell.run"]);
});
