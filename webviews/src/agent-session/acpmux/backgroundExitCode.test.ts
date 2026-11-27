// A background shell's end names its exit code (acpmux `background_task_update.exitCode`: Codex's,
// and Claude Code's read from its summary); the call that started it keeps it, so its opened Shell
// block can say "Exit code N" (conversation/CommandRow.tsx).
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { settleReact } from "../../../test/support/domTeardown";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = {
  window: "window" in scope,
  document: "document" in scope,
  values: { window: scope.window, document: scope.document },
};

beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
afterAll(async () => {
  await settleReact();
  for (const key of ["window", "document"] as const)
    if (saved[key]) scope[key] = saved.values[key];
    else delete scope[key];
});

type Daemon = { record: (target: string, step: unknown, at?: number) => unknown };
type Tool = { id: string; description?: string; background?: { state: string; exitCode?: number } };
type Row = {
  kind: string;
  items?: { tool?: Tool }[];
  backgroundTask?: { toolCallId: string; description?: string; command: string; summary?: string; state: string };
};

const update = (fields: Record<string, unknown>) => ({ update: fields });

test("a background shell's call keeps the exit code its end reported", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  const daemon = socket as unknown as Daemon;
  const shell = (id: string, command: string, description?: string) => [
    update({
      sessionUpdate: "tool_call",
      toolCallId: id,
      title: command,
      kind: "execute",
      status: "in_progress",
      rawInput: { command, description, run_in_background: true },
      _meta: { claude: { tool: "Bash" } },
    }),
    update({ sessionUpdate: "tool_call_update", toolCallId: id, status: "completed" }),
    update({ sessionUpdate: "background_task_update", toolCallId: id, taskId: `t-${id}`, command, state: "running" }),
  ];
  const steps = [
    { mux: "user_message", msg: { text: "Run the benches" } },
    { mux: "turn_started", msg: {} },
    ...shell("bench", "cargo bench", "Run bench"),
    ...shell("serve", "npm run dev"),
    ...["inferred", "authored"].flatMap((id) => [
      update({ sessionUpdate: "tool_call", toolCallId: id, title: "Bash", kind: "execute", status: "in_progress" }),
      update({ sessionUpdate: "background_task_update", toolCallId: id, description: "bun test", state: "running" }),
      update({
        sessionUpdate: "tool_call_update",
        toolCallId: id,
        rawInput: { command: "bun test", ...(id === "authored" && { description: "bun test" }) },
      }),
      update({ sessionUpdate: "tool_call_update", toolCallId: id, status: "completed" }),
      update({ sessionUpdate: "background_task_update", toolCallId: id, state: "completed" }),
    ]),
    // A later running update confirms an orphan's command. Its sparse completion can quote that
    // command in the SDK summary without turning it back into a description.
    update({ sessionUpdate: "background_task_update", toolCallId: "echo", description: "bun test", state: "running" }),
    update({ sessionUpdate: "background_task_update", toolCallId: "echo", command: "bun test", state: "running" }),
    update({
      sessionUpdate: "background_task_update",
      toolCallId: "echo",
      state: "completed",
      summary: 'Background command "bun test" completed (exit code 0)',
    }),
    update({
      sessionUpdate: "background_task_update",
      toolCallId: "bench",
      taskId: "t-bench",
      command: "cargo bench",
      state: "failed",
      description: "Secondary label",
      summary: 'Background command "Run bench" failed (exit code 101)',
      exitCode: 101,
    }),
    // A task whose launch call is on another page reports its name once. Its terse completion
    // still has that name and the command for disclosure.
    update({
      sessionUpdate: "background_task_update",
      toolCallId: "orphan",
      command: "git worktree add lane",
      description: "Create worktree for lane",
      state: "running",
    }),
    update({ sessionUpdate: "background_task_update", toolCallId: "orphan", state: "completed" }),
    // Older SDK orphan updates recorded the description as the command. The notice identifies
    // the subject explicitly, while ordinary summary text stays in the details.
    update({
      sessionUpdate: "background_task_update",
      toolCallId: "legacy",
      command: "Create worktree for lane",
      summary: 'Background command "Create worktree for lane" completed (exit code 0)',
      state: "completed",
      exitCode: 0,
    }),
    update({
      sessionUpdate: "background_task_update",
      toolCallId: "plain",
      command: "./custom-tool",
      summary: 'Output: Background command "do not use this" completed (exit code 0)',
      state: "completed",
    }),
    // An end that names no code (a stop) keeps none.
    update({
      sessionUpdate: "background_task_update",
      toolCallId: "serve",
      command: "npm run dev",
      description: "Start the dev server",
      state: "stopped",
    }),
    { mux: "turn_result", msg: { status: "completed" } },
  ];
  for (const step of steps) daemon.record(mockHost.sessionId!, step);
  let rows: Row[] = [];
  const wakes: Array<() => void> = [];
  const tools = () =>
    rows.flatMap((row) => (row.kind === "activity" ? (row.items ?? []).flatMap((item) => item.tool ?? []) : []));
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      rows = snapshot.rows as Row[];
      for (const wake of wakes.splice(0)) wake();
    },
    undefined,
    () => socket as unknown as WebSocket,
  );
  try {
    while (
      !tools().find((tool) => tool.id === "serve")?.background ||
      tools().find((t) => t.id === "serve")?.background?.state === "running"
    )
      await new Promise<void>((resolve) => wakes.push(resolve));
    const notice = (id: string) => rows.find((row) => row.backgroundTask?.toolCallId === id)?.backgroundTask;
    expect(notice("orphan")).toMatchObject({
      command: "git worktree add lane",
      description: "Create worktree for lane",
      state: "completed",
    });
    expect(notice("legacy")).toMatchObject({
      description: "Create worktree for lane",
      command: "Create worktree for lane",
      summary: 'Background command "Create worktree for lane" completed (exit code 0)',
    });
    expect(notice("plain")?.description).toBeUndefined();
    expect(notice("echo")).toMatchObject({ command: "bun test", state: "completed" });
    expect(notice("echo")?.description).toBeUndefined();
    expect(tools().find((tool) => tool.id === "inferred")?.description).toBeUndefined();
    expect(tools().find((tool) => tool.id === "authored")?.description).toBe("bun test");
    const bench = tools().find((tool) => tool.id === "bench")!;
    expect(bench.description).toBe("Run bench");
    expect(bench.background).toMatchObject({ state: "failed", exitCode: 101 });
    const serve = tools().find((tool) => tool.id === "serve")!;
    expect(serve.description).toBe("Start the dev server");
    expect(serve.background?.state).toBe("stopped");
    expect(serve.background?.exitCode).toBeUndefined();
  } finally {
    client.close?.();
  }
});
