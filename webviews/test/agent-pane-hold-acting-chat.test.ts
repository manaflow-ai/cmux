// #22233 review: while a chat switch holds the pane on the chat before (until the next chat's
// attach is in), the client already names the next chat as selected. Stop pressed on the chat the
// pane still draws went to the hidden chat and cancelled its turn. An action goes to the chat on
// screen.
// #22264 review: a chat's own answer during that hold (its model options) must not land on the
// chat opening, and a grouped permission answer from the drawn chat must not leave an error on it.
// #20930 review: a Use tools toggle (Sources +) during that hold goes to the chat on screen, and a
// reply that comes back after the pane switched away and back does not overwrite the chat's tools.
// #24272 review: an MCP server's Reconnect (the Inspector's Connectors) during that hold goes to the
// chat on screen, whose server it names, not the chat opening.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";

const SESSION_A = "hold-acting-a";
const SESSION_B = "hold-acting-b";
const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = { window: scope.window, document: scope.document, had: "window" in scope };

beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});

afterAll(() => {
  if (saved.had) Object.assign(scope, { window: saved.window, document: saved.document });
  else {
    delete scope.window;
    delete scope.document;
  }
});

const GROUP_OPS = ["_acpmux/permission_groups", "_acpmux/permission_group_respond", "_acpmux/permission_chat_revoke"];

/** The row a held `_acpmux/set_tools` reply carries. */
const STALE_TOOL = { id: "mcp:stale", name: "stale", kind: "mcp", source: "claude", enabled: false, canToggle: true };

type Message = { id?: number; method: string; params?: Record<string, unknown> };

const summary = (sessionId: string) => ({
  sessionId,
  cwd: "/home/dev/project",
  title: sessionId,
  harness: "codex",
  status: "running",
  updatedAt: 1,
});

/** acpmux with chat B's attach held, recording every message the pane sends. */
class HoldingSocket {
  readyState = 0;
  onopen: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onclose: (() => void) | null = null;
  onmessage: ((message: { data: string }) => void) | null = null;
  sent: Message[] = [];
  holdB = true;
  /** Holds chat B's permission groups read: B's attach is in, the hold is not released yet. */
  holdGroupsB = false;
  private heldGroupsB?: Message;
  private groupsB?: () => void;
  readonly readingGroupsB = new Promise<void>((resolve) => (this.groupsB = resolve));
  /** Holds `_acpmux/set_tools` until `releaseSetTools`. */
  holdSetTools = false;
  private heldSetTools?: Message;
  private setTools?: () => void;
  readonly settingTools = new Promise<void>((resolve) => (this.setTools = resolve));
  private heldB?: Message;
  private attachedB?: () => void;
  readonly attachingB = new Promise<void>((resolve) => (this.attachedB = resolve));

  constructor() {
    queueMicrotask(() => {
      this.readyState = 1;
      this.onopen?.();
    });
  }

  send(raw: string): void {
    const message = JSON.parse(raw) as Message;
    this.sent.push(message);
    if (message.id === undefined) return;
    if (message.method === "_acpmux/attach" && message.params?.sessionId === SESSION_B && this.holdB) {
      this.heldB = message;
      this.attachedB?.();
      return;
    }
    if (message.method === "_acpmux/permission_groups" && message.params?.sessionId === SESSION_B && this.holdGroupsB) {
      this.heldGroupsB = message;
      this.groupsB?.();
      return;
    }
    if (message.method === "_acpmux/set_tools" && this.holdSetTools) {
      this.heldSetTools = message;
      this.setTools?.();
      return;
    }
    queueMicrotask(() => this.reply(message));
  }

  close(): void {
    this.readyState = 3;
  }

  releaseB(): void {
    if (this.heldB) this.reply(this.heldB);
  }

  releaseSetTools(): void {
    if (this.heldSetTools) this.reply(this.heldSetTools);
  }

  releaseGroupsB(): void {
    if (this.heldGroupsB) this.fail(this.heldGroupsB);
  }

  private fail(message: Message): void {
    const error = { code: -32603, message: "unavailable" };
    this.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: message.id, error }) });
  }

  private reply(message: Message): void {
    const sessionId = String(message.params?.sessionId ?? "");
    const result =
      message.method === "initialize"
        ? { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: GROUP_OPS } } }
        : message.method === "_acpmux/watch"
          ? { sessions: [summary(SESSION_A), summary(SESSION_B)] }
          : message.method === "_acpmux/attach"
            ? { session: summary(sessionId), lastSeq: 0, events: [] }
            : message.method === "_acpmux/events"
              ? { events: [], hasMore: false, lastSeq: 0 }
              : message.method === "session/set_config_option"
                ? { configOptions: [{ id: "model", currentValue: `${sessionId}-model`, options: [] }] }
                : message.method === "_acpmux/set_tools"
                  ? { tools: [STALE_TOOL], toolsMutable: true, applied: "now" }
                  : {};
    if (message.method === "_acpmux/permission_groups") return this.fail(message);
    this.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result }) });
  }
}

const connect = (socket: HoldingSocket) =>
  AcpmuxDirectClient.connect(
    {
      protocolVersion: 1,
      transport: "acpmux-websocket",
      endpoint: "ws://hold.invalid/",
      token: "t",
      sessionId: SESSION_A,
    },
    () => undefined,
    undefined,
    () => socket as unknown as WebSocket,
  );

test("Stop during a switch's hold cancels the chat on screen, not the chat opening", async () => {
  const socket = new HoldingSocket();
  const client = await AcpmuxDirectClient.connect(
    {
      protocolVersion: 1,
      transport: "acpmux-websocket",
      endpoint: "ws://hold.invalid/",
      token: "t",
      sessionId: SESSION_A,
    },
    () => undefined,
    undefined,
    () => socket as unknown as WebSocket,
  );
  try {
    const switching = client.select(SESSION_B);
    await socket.attachingB;
    // The pane still draws chat A (the hold): the person presses Stop on it.
    await client.cancel();
    const cancels = socket.sent.filter((message) => message.method === "session/cancel");
    expect(cancels.map((message) => message.params?.sessionId)).toEqual([SESSION_A]);
    socket.releaseB();
    await switching;
  } finally {
    client.close();
  }
});

test("a model pick answered during a switch's hold stays the chat on screen's, not the chat opening's", async () => {
  const socket = new HoldingSocket();
  socket.holdB = false;
  socket.holdGroupsB = true;
  const client = await connect(socket);
  try {
    const switching = client.select(SESSION_B);
    // B's attach is in (its summary is the client's), its permissions read is not: still held on A.
    await socket.readingGroupsB;
    await client.setConfig("model", "next");
    socket.releaseGroupsB();
    await switching;
    const options = (client as unknown as { summary?: { configOptions?: { currentValue?: string }[] } }).summary
      ?.configOptions;
    expect(options?.map((option) => option.currentValue) ?? []).not.toContain(`${SESSION_A}-model`);
  } finally {
    client.close();
  }
});

test("a grouped permission answer during a switch's hold leaves no error on the chat opening", async () => {
  const socket = new HoldingSocket();
  const client = await connect(socket);
  try {
    const switching = client.select(SESSION_B);
    await socket.attachingB;
    await expect(client.permissionGroup("group-a", 1, "allow_once")).rejects.toThrow();
    expect(client.permissions.state.error).toBeUndefined();
    expect(socket.sent.filter((message) => message.method === "_acpmux/permission_group_respond")).toHaveLength(0);
    socket.releaseB();
    await switching;
  } finally {
    client.close();
  }
});

test("a Use tools toggle during a switch's hold goes to the chat on screen, not the chat opening", async () => {
  const socket = new HoldingSocket();
  const client = await connect(socket);
  try {
    const switching = client.select(SESSION_B);
    await socket.attachingB;
    // The pane still draws chat A: the person turns one of its tools off in Sources +.
    await client.setTool("mcp:github", false);
    const sets = socket.sent.filter((message) => message.method === "_acpmux/set_tools");
    expect(sets.map((message) => message.params?.sessionId)).toEqual([SESSION_A]);
    socket.releaseB();
    await switching;
  } finally {
    client.close();
  }
});

test("a Use tools reply that lands after a switch away and back leaves the chat's tools alone", async () => {
  const socket = new HoldingSocket();
  socket.holdB = false;
  socket.holdSetTools = true;
  const client = await connect(socket);
  try {
    const toggling = client.setTool("mcp:github", false);
    await socket.settingTools;
    await client.select(SESSION_B);
    await client.select(SESSION_A);
    socket.releaseSetTools();
    await toggling;
    const tools = (client as unknown as { summary?: { tools?: { id: string }[] } }).summary?.tools;
    expect(tools?.map((tool) => tool.id) ?? []).not.toContain(STALE_TOOL.id);
  } finally {
    client.close();
  }
});

test("an MCP Reconnect during a switch's hold goes to the chat on screen, not the chat opening", async () => {
  const socket = new HoldingSocket();
  const client = await connect(socket);
  try {
    const switching = client.select(SESSION_B);
    await socket.attachingB;
    // The pane still draws chat A: the person presses Reconnect on one of its failed servers.
    await client.reconnectMcp("github");
    const asks = socket.sent.filter((message) => message.method === "_acpmux/mcp/reconnect");
    expect(asks.map((message) => message.params?.sessionId)).toEqual([SESSION_A]);
    socket.releaseB();
    await switching;
  } finally {
    client.close();
  }
});
