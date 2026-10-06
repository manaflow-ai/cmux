import { describe, expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { promptText } from "../attachments";
import {
  SHELL_ROW,
  ShellRuns,
  cleanShellOutput,
  shellAttachment,
  shellContextAttachments,
  withShellRows,
  type ShellRun,
} from "./shellRuns";

/// A fake host: `shell.run` answers an id, each `shell.read` takes the next scripted chunk.
function host(chunks: { output?: string; exit?: { code?: number; signal?: string } }[]) {
  const calls: { method: string; params?: Record<string, unknown> }[] = [];
  let next = 0;
  const waiting: (() => void)[] = [];
  const callNative = async <T>(method: string, params?: Record<string, unknown>): Promise<T> => {
    calls.push({ method, params });
    if (method === "shell.run") return { id: "h1" } as T;
    if (method === "shell.stop") return {} as T;
    if (method === "shell.read") {
      const chunk = chunks[next++];
      if (!chunk) await new Promise<void>((resolve) => waiting.push(resolve));
      const offset = (params?.after as number) + (chunk?.output?.length ?? 0);
      return { output: chunk?.output ?? "", next: offset, ...(chunk?.exit ? { exit: chunk.exit } : {}) } as T;
    }
    throw new Error(`unexpected ${method}`);
  };
  return { calls, callNative, release: () => waiting.splice(0).forEach((resolve) => resolve()) };
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

describe("shell runs", () => {
  test("a command runs on the host in the chat's folder and its output streams into the run", async () => {
    const fake = host([{ output: "a\n" }, { output: "b\n", exit: { code: 0 } }]);
    const runs = new ShellRuns(fake.callNative, () => 1_000);
    const run = runs.start("ls", { cwd: "/repo", sessionId: "s1" });
    expect(run.status).toBe("running");
    await settle();
    await settle();
    const done = runs.get(run.id)!;
    expect(fake.calls[0]).toEqual({ method: "shell.run", params: { command: "ls", cwd: "/repo" } });
    expect(fake.calls.filter((call) => call.method === "shell.read").map((call) => call.params?.after)).toEqual([0, 2]);
    expect(done.output).toBe("a\nb\n");
    expect(done.status).toBe("done");
    expect(done.exitCode).toBe(0);
  });

  test("a non-zero exit is a failure with its code; a signal after Stop reads as stopped", async () => {
    const failing = host([{ output: "nope\n", exit: { code: 2 } }]);
    const runs = new ShellRuns(failing.callNative);
    const run = runs.start("false", { sessionId: "s1" });
    await settle();
    await settle();
    expect(runs.get(run.id)).toMatchObject({ status: "failed", exitCode: 2 });

    const stopped = host([]);
    const other = new ShellRuns(stopped.callNative);
    const long = other.start("sleep 100", { sessionId: "s1" });
    await settle();
    other.stop(long.id);
    await settle();
    expect(stopped.calls.some((call) => call.method === "shell.stop" && call.params?.id === "h1")).toBe(true);
    stopped.release();
    await settle();
  });

  test("Stop before the host answered stops the command once it starts", async () => {
    const fake = host([{ exit: { signal: "SIGINT" } }]);
    const runs = new ShellRuns(fake.callNative);
    const run = runs.start("yes", { sessionId: "s1" });
    runs.stop(run.id);
    await settle();
    await settle();
    expect(fake.calls.map((call) => call.method)).toContain("shell.stop");
    expect(runs.get(run.id)!.status).toBe("stopped");
  });

  test("a host that refuses the command leaves a failed block with its reason, never a terminal", async () => {
    const runs = new ShellRuns(async () => {
      throw new Error("Shell commands need a key press in this pane");
    });
    const run = runs.start("ls", { sessionId: "s1" });
    await settle();
    expect(runs.get(run.id)).toMatchObject({ status: "failed", error: "Shell commands need a key press in this pane" });
  });

  test("runs made before the chat had a session join the session it gets", async () => {
    const fake = host([]);
    const runs = new ShellRuns(fake.callNative);
    const run = runs.start("pwd", { cwd: "/repo" });
    expect(runs.forSession("s9")).toEqual([]);
    runs.claim("s9");
    expect(runs.forSession("s9").map((item) => item.id)).toEqual([run.id]);
    fake.release();
  });

  test("the latest running command of a chat is the one Ctrl-C stops", async () => {
    const fake = host([]);
    const runs = new ShellRuns(fake.callNative);
    runs.start("one", { sessionId: "s1" });
    const two = runs.start("two", { sessionId: "s1" });
    runs.start("elsewhere", { sessionId: "s2" });
    expect(runs.running("s1")?.id).toBe(two.id);
    fake.release();
  });
});

describe("shell output", () => {
  test("escape sequences go and a carriage return keeps the line's last state", () => {
    expect(cleanShellOutput("\u001b[31mred\u001b[0m\n")).toBe("red\n");
    expect(cleanShellOutput("10%\r50%\r100%\ndone\r\n")).toBe("100%\ndone\n");
    expect(cleanShellOutput("\u001b]0;title\u0007ok")).toBe("ok");
  });
});

describe("shell blocks in the transcript", () => {
  const row = (id: string, at: number): AcpmuxRow => ({ id, at, version: 1, kind: "assistant", text: id });
  const run = (id: string, startedAt: number): ShellRun => ({
    id,
    command: id,
    startedAt,
    status: "done",
    output: "",
    truncated: false,
    version: 3,
  });

  test("each block sits where it ran among the chat's rows", () => {
    const rows = [row("a", 10), row("b", 20), row("c", 30)];
    const spliced = withShellRows(rows, [run("x", 25), run("y", 99)]);
    expect(spliced.map((item) => item.id)).toEqual(["a", "b", "shell-x", "c", "shell-y"]);
    const block = spliced[2]!;
    expect(block.kind).toBe(SHELL_ROW);
    expect(block.version).toBe(3);
    expect(withShellRows(rows, [])).toBe(rows);
  });
});

describe("shell context for the agent", () => {
  test("a command's chip carries its output, exit status and folder into the next prompt", () => {
    const done: ShellRun = {
      id: "r1",
      command: "git status",
      cwd: "/repo",
      startedAt: 1,
      status: "failed",
      exitCode: 1,
      output: "fatal: not a git repository\n",
      truncated: false,
      version: 2,
    };
    const chip = shellAttachment(done);
    expect(chip).toMatchObject({ kind: "text", name: "$ git status", shellRun: "r1" });
    const [filled] = shellContextAttachments([chip], (id) => (id === "r1" ? done : undefined));
    expect(filled!.name).toBe("$ git status (exit 1)");
    const prompt = promptText("why?", [filled!]);
    expect(prompt).toContain("why?");
    expect(prompt).toContain("fatal: not a git repository");
    expect(prompt).toContain("/repo");
  });

  test("a long output keeps its end, which is where errors are", () => {
    const output = "x".repeat(40_000) + "\nthe error\n";
    const run: ShellRun = { id: "r", command: "build", startedAt: 1, status: "done", exitCode: 0, output, truncated: false, version: 1 };
    const [filled] = shellContextAttachments([shellAttachment(run)], () => run);
    expect(filled!.text!.length).toBeLessThan(20_000);
    expect(filled!.text).toContain("the error");
  });
});
