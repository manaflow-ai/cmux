// l10n-allow-file: test fixtures, not shipped UI.
// Issue #45951: the pane's acpmux client lists a chat's daemon-owned background tasks
// (`_acpmux/bg/list`) beside its harness shells, routes a task's tail and Stop to `_acpmux/bg/*`,
// and hands each `_acpmux/bg_update` to the registry's listeners as a process of the chat.
import { expect, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";

const CHAT = "0190a000-0000-7000-8000-0000000000e5";
const START = Date.UTC(2026, 10, 17, 1, 0, 0);
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

const task = (id: string, fields: Record<string, unknown> = {}) => ({
  id,
  sessionId: CHAT,
  command: `gh run watch ${id}`,
  description: "Watch CI",
  state: "running",
  startedAt: START,
  endedAt: null,
  exitCode: null,
  tail: "",
  ...fields,
});

function fakeDaemon(options: { bgList?: "fails" } = {}) {
  const asked: { method: string; params: any }[] = [];
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/x",
    title: "x",
    harness: "claude",
    family: "claude",
    status: "ready",
    turnCount: 1,
    updatedAt: START,
  };
  let socket: any;
  const answer = (method: string, params: any): unknown => {
    asked.push({ method, params });
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, lastSeq: 0, events: [], hasMore: false };
      case "_acpmux/process/list":
        return {
          processes: [{ id: `${CHAT}/toolu_1`, sessionId: CHAT, command: "vite", state: "running", startedAt: START }],
          nextCursor: null,
        };
      case "_acpmux/bg/list":
        if (options.bgList === "fails") throw new Error("not served");
        return { tasks: [task("bg-a"), task("bg-b", { state: "exited", exitCode: 0, endedAt: START + 5 })] };
      case "_acpmux/bg/output":
        return { ...task(params.id), data: btoa("watching\n"), fromByte: 0, nextByte: 9 };
      case "_acpmux/bg/stop":
        return task(params.id, { state: "stopped" });
      default:
        return null;
    }
  };
  const open = () => {
    socket = {
      readyState: 1,
      send(raw: string) {
        const message = JSON.parse(raw);
        if (message.id === undefined) return;
        queueMicrotask(() => {
          let reply: unknown;
          try {
            reply = { jsonrpc: "2.0", id: message.id, result: answer(message.method, message.params) };
          } catch (error) {
            reply = { jsonrpc: "2.0", id: message.id, error: { code: -32601, message: String(error) } };
          }
          socket.onmessage?.({ data: JSON.stringify(reply) });
        });
      },
      close() {},
    };
    queueMicrotask(() => socket.onopen?.());
    return socket as WebSocket;
  };
  const push = (method: string, params: unknown) =>
    socket.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", method, params }) });
  return { open, asked, push };
}

async function client(daemon: ReturnType<typeof fakeDaemon>) {
  const connected = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    () => {},
    undefined,
    daemon.open,
  );
  await tick();
  return connected;
}

test("a chat's daemon tasks are listed after its shells, as processes of the chat", async () => {
  const daemon = fakeDaemon();
  const reply = await (await client(daemon)).listProcesses(CHAT);
  expect(reply.processes?.map((p: any) => [p.id, p.state, p.command])).toEqual([
    [`${CHAT}/toolu_1`, "running", "vite"],
    [`${CHAT}/bg:bg-a`, "running", "gh run watch bg-a"],
    [`${CHAT}/bg:bg-b`, "exited", "gh run watch bg-b"],
  ]);
});

test("a connection bg/list is not served to lists the shells alone", async () => {
  const reply = await (await client(fakeDaemon({ bgList: "fails" }))).listProcesses(CHAT);
  expect(reply.processes?.map((p: any) => p.id)).toEqual([`${CHAT}/toolu_1`]);
});

test("a daemon task's tail and Stop go to bg/output and bg/stop", async () => {
  const daemon = fakeDaemon();
  const connected = await client(daemon);
  const tail = (await connected.tailProcess(`${CHAT}/bg:bg-a`, 16_384)) as { data: string; fromByte: number };
  expect(atob(tail.data)).toBe("watching\n");
  await connected.killProcess(`${CHAT}/bg:bg-a`);
  expect(daemon.asked.filter((a) => a.method.startsWith("_acpmux/bg/") && a.method !== "_acpmux/bg/list")).toEqual([
    { method: "_acpmux/bg/output", params: { sessionId: CHAT, id: "bg-a", maxBytes: 16_384 } },
    { method: "_acpmux/bg/stop", params: { sessionId: CHAT, id: "bg-a" } },
  ]);
  expect(daemon.asked.some((a) => a.method === "_acpmux/process/kill")).toBe(false);
});

test("a bg_update reaches the registry's listeners as the chat's process, and the task's own", async () => {
  const daemon = fakeDaemon();
  const connected = await client(daemon);
  const processes: unknown[] = [];
  const tasks: unknown[] = [];
  connected.watchProcesses((process) => processes.push(process));
  const stop = connected.watchBgTasks((value) => tasks.push(value));
  daemon.push("_acpmux/bg_update", { task: task("bg-c") });
  daemon.push("_acpmux/bg_update", { task: task("bg-c", { state: "exited", exitCode: 1, endedAt: START + 9 }) });
  expect(processes).toMatchObject([
    { id: `${CHAT}/bg:bg-c`, state: "running", startedAt: START },
    { id: `${CHAT}/bg:bg-c`, state: "failed", exitCode: 1, endedAt: START + 9 },
  ]);
  expect(tasks).toHaveLength(2);
  stop();
  daemon.push("_acpmux/bg_update", { task: task("bg-d") });
  expect(tasks).toHaveLength(2);
});
