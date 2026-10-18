import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";

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
afterAll(() => {
  for (const key of ["window", "document"] as const)
    if (saved[key]) scope[key] = saved.values[key];
    else delete scope[key];
});

const process = (sessionId: string, state: string = "running") => ({
  id: `${sessionId}/task-1`,
  sessionId,
  toolCallId: "tool-1",
  taskId: "task-1",
  harness: "claude",
  command: "bun run dev",
  cwd: "/tmp/cmux",
  startedAt: 1_000,
  state,
  origin: "background",
  outputBytes: 7,
});

test("background processes are listed, surfaced in snapshots, and expose tail/kill", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  let socket: (MockAcpmuxSocket & { sendProcessUpdate: (value: unknown) => void }) | undefined;
  let snapshot: any;
  class ProcessHost extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const answer = (this as any).answer.bind(this);
      (this as any).answer = async (method: string, params: Record<string, unknown>) => {
        if (method === "_acpmux/process/list") return { processes: [process(String(params.sessionId))] };
        if (method === "_acpmux/process/tail") return { data: "bG9nCg==", fromByte: 0, nextByte: 4, eof: false };
        if (method === "_acpmux/process/kill") return {};
        return answer(method, params);
      };
      (this as any).sendProcessUpdate = (value: unknown) =>
        (this as any).deliver({
          jsonrpc: "2.0",
          method: "_acpmux/process_update",
          params: { process: value },
        });
      socket = this as any;
    }
  }
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (next) => {
      snapshot = next;
    },
    undefined,
    () => new ProcessHost() as unknown as WebSocket,
  );
  try {
    expect(snapshot.processes).toHaveLength(1);
    expect(snapshot.processes[0].state).toBe("running");
    expect(snapshot.rows.some((row: any) => row.kind === "backgroundTask" && row.backgroundTask.processId)).toBe(true);

    const tail = await client.tailProcess(snapshot.processes[0].id);
    expect(tail).toEqual({
      data: "bG9nCg==",
      fromByte: 0,
      nextByte: 4,
      eof: false,
    });
    await client.killProcess(snapshot.processes[0].id);
    socket!.sendProcessUpdate(process(String(mockHost.sessionId), "killed"));
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(snapshot.processes[0].state).toBe("killed");
    expect(snapshot.rows.find((row: any) => row.backgroundTask?.processId)?.backgroundTask.state).toBe("stopped");
  } finally {
    client.close();
  }
});
