import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { MacRuntimeClient } from "../src/lib/macRuntimeClient";

class FakeWebSocket extends EventTarget {
  static readonly CONNECTING = 0;
  static readonly OPEN = 1;
  static readonly CLOSING = 2;
  static readonly CLOSED = 3;
  static current: FakeWebSocket | null = null;

  readonly sent: Array<Record<string, unknown>> = [];
  binaryType: BinaryType = "blob";
  readyState: number = FakeWebSocket.CONNECTING;

  constructor(
    readonly url: string,
    readonly protocols?: string | string[],
  ) {
    super();
    FakeWebSocket.current = this;
  }

  send(data: string | ArrayBufferLike | Blob | ArrayBufferView): void {
    if (typeof data !== "string") throw new Error("Expected a JSON text frame");
    this.sent.push(JSON.parse(data) as Record<string, unknown>);
  }

  close(): void {
    if (this.readyState === FakeWebSocket.CLOSED) return;
    this.readyState = FakeWebSocket.CLOSED;
    this.dispatchEvent(new CloseEvent("close"));
  }

  open(): void {
    this.readyState = FakeWebSocket.OPEN;
    this.dispatchEvent(new Event("open"));
  }

  receive(value: Record<string, unknown>): void {
    this.dispatchEvent(new MessageEvent("message", { data: JSON.stringify(value) }));
  }
}

async function waitForRequest(
  socket: FakeWebSocket,
  method: string,
  occurrence = 0,
): Promise<Record<string, unknown>> {
  for (let attempt = 0; attempt < 20; attempt += 1) {
    const request = socket.sent.filter((candidate) => candidate.method === method)[occurrence];
    if (request) return request;
    await Promise.resolve();
  }
  throw new Error(`Request ${method} was not sent`);
}

function respond(
  socket: FakeWebSocket,
  request: Record<string, unknown>,
  result: Record<string, unknown> = {},
): void {
  socket.receive({ id: request.id, ok: true, result });
}

async function connectedClient(): Promise<{
  client: MacRuntimeClient;
  socket: FakeWebSocket;
}> {
  const client = new MacRuntimeClient("ws://127.0.0.1:7683/cmux", "cmux_web_test");
  const socket = FakeWebSocket.current;
  if (!socket) throw new Error("Expected a WebSocket instance");
  socket.open();
  expect(socket.sent[0]).toMatchObject({
    type: "cmux.web.hello",
    protocol: "cmux.web/1",
    protocol_version: 1,
    token: "cmux_web_test",
  });
  expect(socket.protocols).toBe("cmux.web.v1");
  socket.receive({
    type: "cmux.web.ready",
    protocol: "cmux.web/1",
    protocol_version: 1,
    connection_id: "connection-1",
  });
  await Promise.resolve();
  return { client, socket };
}

describe("MacRuntimeClient", () => {
  beforeEach(() => {
    FakeWebSocket.current = null;
    vi.stubGlobal("WebSocket", FakeWebSocket);
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

  it("closes a half-open socket when its heartbeat request times out", async () => {
    vi.useFakeTimers();
    const { client, socket } = await connectedClient();

    await vi.advanceTimersByTimeAsync(10_000);
    expect(socket.sent.some((request) => request.method === "mobile.host.status")).toBe(true);
    await vi.advanceTimersByTimeAsync(15_000);

    expect(socket.readyState).toBe(FakeWebSocket.CLOSED);
    await client.close();
  });

  it("closes when an unconsumed event exceeds the byte backlog budget", async () => {
    const { client, socket } = await connectedClient();
    socket.receive({
      kind: "event",
      topic: "workspace.updated",
      payload: { diagnostic: "x".repeat(5 * 1024 * 1024) },
    });
    await Promise.resolve();

    expect(socket.readyState).toBe(FakeWebSocket.CLOSED);
    await client.close();
  });

  it("delivers live terminal bytes that begin at the replay boundary", async () => {
    const { client, socket } = await connectedClient();
    const attaching = client.attachSurface(42n);
    const attachRequest = await waitForRequest(socket, "terminal.attach");
    respond(socket, attachRequest);
    const replayRequest = await waitForRequest(socket, "terminal.replay");
    const stream = await attaching;

    socket.receive({
      kind: "event",
      topic: "terminal.bytes",
      payload: {
        surface_id: "42",
        seq: "3",
        data_b64: "ZA==",
      },
    });
    respond(socket, replayRequest, {
      seq: Number.MAX_SAFE_INTEGER + 8,
      seq_decimal: "3",
      columns: 80,
      rows: 24,
      snapshot_data_b64: "YWJj",
    });

    const replay = await stream.next();
    expect(replay.event).toBe("vt-state");
    expect(Array.from(replay.data as Uint8Array)).toEqual([97, 98, 99]);

    const output = await stream.next();
    expect(output.event).toBe("output");
    expect(Array.from(output.data as Uint8Array)).toEqual([100]);

    stream.close();
    await client.close();
  });

  it("initializes a quiet terminal from an empty replay", async () => {
    const { client, socket } = await connectedClient();
    const attaching = client.attachSurface(42n);
    const attachRequest = await waitForRequest(socket, "terminal.attach");
    respond(socket, attachRequest);
    const replayRequest = await waitForRequest(socket, "terminal.replay");
    const stream = await attaching;
    respond(socket, replayRequest, {
      seq: 0,
      seq_decimal: "0",
      columns: 100,
      rows: 30,
    });

    const replay = await stream.next();
    expect(replay).toMatchObject({ event: "vt-state", cols: 100, rows: 30 });
    expect(Array.from(replay.data as Uint8Array)).toEqual([]);

    stream.close();
    await client.close();
  });

  it("chunks terminal input below the browser-to-Mac message ceiling", async () => {
    const { client, socket } = await connectedClient();
    const input = "\u0000".repeat(600);
    const sending = client.send(42n, { text: input });

    const first = await waitForRequest(socket, "terminal.input", 0);
    respond(socket, first);
    const second = await waitForRequest(socket, "terminal.input", 1);
    respond(socket, second);
    await sending;

    const requests = socket.sent.filter((request) => request.method === "terminal.input");
    expect(requests).toHaveLength(2);
    expect(requests.map((request) => (
      (request.params as Record<string, unknown>).text as string
    )).join("")).toBe(input);
    for (const request of requests) {
      expect(new TextEncoder().encode(JSON.stringify(request)).byteLength).toBeLessThanOrEqual(4 * 1024);
    }

    await client.close();
  });

  it("maps shared named-key chords onto Mac terminal input bytes", async () => {
    const { client, socket } = await connectedClient();
    const expected = ["\u0003", "\u001b[Z", "\u001b", "\u001bx", "\r"];
    const sending = client.sendKey(42n, [
      "ctrl+c",
      "shift+tab",
      "ctrl+[",
      "alt+x",
      "enter",
    ]);
    for (const [index, text] of expected.entries()) {
      const request = await waitForRequest(socket, "terminal.input", index);
      expect((request.params as Record<string, unknown>).text).toBe(text);
      respond(socket, request);
    }
    await sending;
    await client.close();
  });

  it("replays when the Mac returns a different effective viewport", async () => {
    const { client, socket } = await connectedClient();
    const attaching = client.attachSurface(42n);
    const attachRequest = await waitForRequest(socket, "terminal.attach");
    respond(socket, attachRequest);
    const initialReplayRequest = await waitForRequest(socket, "terminal.replay", 0);
    const stream = await attaching;
    respond(socket, initialReplayRequest, {
      seq: "0",
      columns: 80,
      rows: 24,
      snapshot_data_b64: "YQ==",
    });
    await stream.next();

    const resizing = client.resizeSurface(42n, 120, 40);
    const viewportRequest = await waitForRequest(socket, "terminal.viewport");
    respond(socket, viewportRequest, { columns: 80, rows: 24 });
    const effectiveReplayRequest = await waitForRequest(socket, "terminal.replay", 1);
    respond(socket, effectiveReplayRequest, {
      seq: "1",
      columns: 80,
      rows: 24,
      snapshot_data_b64: "Yg==",
    });
    await resizing;

    const replay = await stream.next();
    expect(replay).toMatchObject({ event: "vt-state", cols: 80, rows: 24 });
    expect(Array.from(replay.data as Uint8Array)).toEqual([98]);

    stream.close();
    await client.close();
  });

  it("keeps terminal byte traffic out of the workspace event stream", async () => {
    const { client, socket } = await connectedClient();
    const subscribing = client.subscribe();
    const subscribeRequest = await waitForRequest(socket, "events.stream");
    expect(subscribeRequest.params).toEqual({
      stream_id: expect.any(String),
      topics: ["workspace.updated"],
    });
    respond(socket, subscribeRequest);
    const stream = await subscribing;

    socket.receive({
      kind: "event",
      topic: "terminal.bytes",
      payload: { surface_id: "42", seq: "0", data_b64: "eA==" },
    });
    socket.receive({
      kind: "event",
      topic: "workspace.updated",
      payload: {},
    });

    await expect(stream.next()).resolves.toEqual({ event: "tree-changed" });

    stream.close();
    await client.close();
  });

  it("turns workspace event overflow into a level-triggered refresh", async () => {
    const { client, socket } = await connectedClient();
    const subscribing = client.subscribe();
    const subscribeRequest = await waitForRequest(socket, "events.stream");
    respond(socket, subscribeRequest);
    const stream = await subscribing;

    for (let index = 0; index < 65; index += 1) {
      socket.receive({
        kind: "event",
        topic: "workspace.updated",
        payload: {},
      });
    }

    await expect(stream.next()).resolves.toEqual({ event: "tree-changed" });

    stream.close();
    await client.close();
  });

  it("keeps browser tab selection local to the Mac runtime adapter", async () => {
    const { client, socket } = await connectedClient();
    const payload = {
      workspaces: [{
        id: "00000000-0000-0000-0000-000000000001",
        title: "Workspace",
        is_selected: true,
        terminals: [
          {
            id: "00000000-0000-0000-0000-000000000011",
            title: "one",
            is_focused: true,
          },
          {
            id: "00000000-0000-0000-0000-000000000012",
            title: "two",
            is_focused: false,
          },
        ],
      }],
    };
    const firstListing = client.listWorkspaces();
    respond(socket, await waitForRequest(socket, "mobile.workspace.list"), payload);
    const firstTree = await firstListing;
    const pane = firstTree.workspaces[0]!.screens[0]!.panes[0]!;
    if (!("active_tab" in pane)) throw new Error("Expected a live pane");
    expect(pane.active_tab).toBe(0n);

    await client.selectTab({ pane: pane.id, index: 1n });
    const secondListing = client.listWorkspaces();
    respond(socket, await waitForRequest(socket, "mobile.workspace.list", 1), payload);
    const secondTree = await secondListing;
    const selectedPane = secondTree.workspaces[0]!.screens[0]!.panes[0]!;
    if (!("active_tab" in selectedPane)) throw new Error("Expected a live pane");
    expect(selectedPane.active_tab).toBe(1n);

    expect(socket.sent.some((request) => request.method === "mobile.surface.focus")).toBe(false);
    await client.close();
  });

  it("keeps an attached surface UUID until viewport cleanup completes", async () => {
    const { client, socket } = await connectedClient();
    const surfaceUUID = "00000000-0000-0000-0000-000000000011";
    const initialListing = client.listWorkspaces();
    respond(socket, await waitForRequest(socket, "mobile.workspace.list"), {
      workspaces: [{
        id: "00000000-0000-0000-0000-000000000001",
        title: "Workspace",
        is_selected: true,
        terminals: [{
          id: surfaceUUID,
          title: "shell",
          is_ready: true,
          is_focused: true,
        }],
      }],
    });
    const tree = await initialListing;
    const surface = tree.workspaces[0]!.screens[0]!.panes[0]!.tabs[0]!.surface;

    const attaching = client.attachSurface(surface);
    respond(socket, await waitForRequest(socket, "terminal.attach"));
    const replayRequest = await waitForRequest(socket, "terminal.replay");
    const stream = await attaching;
    respond(socket, replayRequest, {
      seq: "0",
      columns: 80,
      rows: 24,
      snapshot_data_b64: "YQ==",
    });
    await stream.next();

    const removedListing = client.listWorkspaces();
    respond(socket, await waitForRequest(socket, "mobile.workspace.list", 1), {
      workspaces: [{
        id: "00000000-0000-0000-0000-000000000001",
        title: "Workspace",
        is_selected: true,
        terminals: [],
      }],
    });
    await removedListing;

    const release = client.releaseSurfaceSize(surface);
    const viewportRequest = await waitForRequest(socket, "terminal.viewport");
    expect((viewportRequest.params as Record<string, unknown>).surface_id).toBe(surfaceUUID);
    respond(socket, viewportRequest, {});
    await release;

    stream.close();
    await client.close();
  });
});
