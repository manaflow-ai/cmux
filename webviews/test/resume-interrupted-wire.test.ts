// l10n-allow-file: fake daemon records and test messages, not shipped UI.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import { HANDOFF_OPS, type Handoff } from "../src/agent-session/acpmux/handoff/protocol";
import { translate } from "../src/agent-session/acpmux/i18n";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import { setNativeHost } from "../src/agent-session/acpmux/native";
import { PERMISSION_GROUP_OPS } from "../src/agent-session/acpmux/permissions/protocol";

const CHAT = "resume-wire-chat";
const SESSION = {
  sessionId: CHAT,
  cwd: "/home/dev/project",
  harness: "codex",
  family: "codex",
  status: "idle",
  turnCount: 1,
  updatedAt: 1,
};
const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = ["window", "document"].map((key) => [key, key in scope, scope[key]] as const);
beforeAll(() => Object.assign(scope, { window: dom.window, document: dom.window.document }));
afterAll(() => {
  for (const [key, had, value] of saved)
    if (had) scope[key] = value;
    else delete scope[key];
  dom.window.close();
});

type Request = { id: number; method: string; params: Record<string, unknown> };
const promptMeta = (request: Request) => request.params._meta as { acpmux: { promptId: string }; cmuxGesture?: string };

class ResumeSocket {
  readyState = 0;
  onopen: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onclose: (() => void) | null = null;
  onmessage: ((message: { data: string }) => void) | null = null;
  sent: Request[] = [];
  autoReplyPrompts = false;
  private promptWaiters: ((request: Request) => void)[] = [];

  constructor(private handoff?: Handoff) {
    queueMicrotask(() => {
      this.readyState = 1;
      this.onopen?.();
    });
  }

  send(raw: string): void {
    const message = JSON.parse(raw) as Request;
    this.sent.push(message);
    if (message.method === "session/prompt") {
      for (const waiter of this.promptWaiters.splice(0)) waiter(message);
      if (this.autoReplyPrompts) queueMicrotask(() => this.reply(message, { stopReason: "end_turn" }));
      return;
    }
    if (message.id === undefined) return;
    const result =
      message.method === "initialize"
        ? {
            protocolVersion: 1,
            _meta: {
              acpmux: {
                origin: "local",
                operations: [
                  ...Object.values(PERMISSION_GROUP_OPS),
                  ...(this.handoff ? Object.values(HANDOFF_OPS) : []),
                ],
              },
            },
          }
        : message.method === "_acpmux/watch"
          ? { sessions: [SESSION] }
          : message.method === "_acpmux/attach"
            ? { session: SESSION, lastSeq: 0, events: [], hasMore: false }
            : message.method === HANDOFF_OPS.get
              ? this.handoff
              : message.method === PERMISSION_GROUP_OPS.groups
                ? {
                    groups: [],
                    chatAllowance: { active: false, expires: "session_stop_or_daemon_restart" },
                    coverage: { label: "acp_requests_only", isolation: "unverified", detail: "ACP requests only" },
                    batching: { windowMs: 100, maxItems: 32, maxPendingGroups: 64, maxReceipts: 64 },
                  }
                : {};
    queueMicrotask(() => this.reply(message, result));
  }

  nextPrompt(index = 0): Promise<Request> {
    const prompt = this.sent.filter((request) => request.method === "session/prompt")[index];
    return prompt ? Promise.resolve(prompt) : new Promise((resolve) => this.promptWaiters.push(resolve));
  }

  reply(request: Request, result: unknown): void {
    this.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: request.id, result }) });
  }

  accept(request: Request): void {
    this.onmessage?.({
      data: JSON.stringify({
        jsonrpc: "2.0",
        method: "_acpmux/prompt_accepted",
        params: { sessionId: CHAT, promptId: promptMeta(request).acpmux.promptId },
      }),
    });
  }

  refuse(request: Request): void {
    this.onmessage?.({
      data: JSON.stringify({
        jsonrpc: "2.0",
        id: request.id,
        error: {
          code: -32000,
          message: "Resume was refused",
          data: { code: "transport.gesture_required", origin: "native" },
        },
      }),
    });
  }

  sessionChanged(change: Partial<typeof SESSION>): void {
    this.onmessage?.({
      data: JSON.stringify({
        jsonrpc: "2.0",
        method: "_acpmux/session_changed",
        params: { session: { ...SESSION, ...change } },
      }),
    });
  }

  close(): void {
    this.readyState = 3;
  }
}

async function connect(handoff?: Handoff, onSnapshot?: (snapshot: AcpmuxSnapshot) => void) {
  let socket!: ResumeSocket;
  const snapshots: AcpmuxSnapshot[] = [];
  let shown!: () => void;
  const ready = new Promise<void>((resolve) => (shown = resolve));
  const client = await AcpmuxDirectClient.connect(
    {
      protocolVersion: 1,
      transport: "acpmux-websocket",
      endpoint: "ws://resume.invalid/",
      token: "test",
      sessionId: CHAT,
    },
    (snapshot) => {
      snapshots.push(snapshot);
      if (snapshot.sessionId === CHAT && snapshot.summary?.sessionId === CHAT) shown();
      onSnapshot?.(snapshot);
    },
    undefined,
    () => {
      socket = new ResumeSocket(handoff);
      return socket as unknown as WebSocket;
    },
  );
  await ready;
  return { client, socket, snapshots };
}

test("Resume sends empty input with its bound identity, and acceptance releases the page before completion", async () => {
  const { client, socket, snapshots } = await connect();
  const gestures: Record<string, unknown>[] = [];
  setNativeHost(async (method, params) => {
    if (method === "transport.gesture") {
      gestures.push(params);
      return { ticket: "resume-ticket" };
    }
    return {};
  });
  try {
    let completed = false;
    const resumed = client.resumeInterrupted(CHAT, "resume-1").then((value) => {
      completed = true;
      return value;
    });
    const prompt = await socket.nextPrompt();
    expect(gestures).toEqual([
      { intent: { method: "session/prompt", params: { promptId: "resume-1", sessionId: CHAT } } },
    ]);
    expect(prompt.params.sessionId).toBe(CHAT);
    expect(prompt.params.prompt).toEqual([]);
    expect(promptMeta(prompt)).toMatchObject({ acpmux: { promptId: "resume-1" }, cmuxGesture: "resume-ticket" });
    expect(client.swapHold()).toBe("composer.send-untaken");
    expect(snapshots.flatMap((snapshot) => snapshot.rows).filter((row) => row.kind === "user")).toEqual([]);

    socket.accept(prompt);
    expect(client.swapHold()).toBeNull();
    expect(completed).toBe(false);
    socket.reply(prompt, { stopReason: "end_turn" });
    expect(await resumed).toBe(CHAT);
    expect(snapshots.flatMap((snapshot) => snapshot.rows).filter((row) => row.kind === "user")).toEqual([]);
  } finally {
    setNativeHost(undefined);
    client.close();
  }
});

test("a refused Resume leaves no empty failed prompt or page hold", async () => {
  const { client, socket, snapshots } = await connect();
  try {
    const resumed = client.resumeInterrupted(CHAT, "resume-refused", "ticket");
    const rejected = resumed.catch((error: unknown) => error);
    const prompt = await socket.nextPrompt();
    socket.refuse(prompt);
    expect(await rejected).toMatchObject({ message: "Resume was refused" });
    expect(client.swapHold()).toBeNull();
    expect(snapshots.flatMap((snapshot) => snapshot.rows).filter((row) => row.kind === "user")).toEqual([]);
  } finally {
    client.close();
  }
});

test("Cloud Resume claims the handoff turn while keeping empty input and its ticket", async () => {
  const { client, socket } = await connect();
  const asked: string[] = [];
  client.handoffTurn = async (sessionId) => {
    asked.push(sessionId);
    return 7;
  };
  try {
    const resumed = client.resumeInterrupted(CHAT, "resume-cloud", "cloud-ticket");
    const prompt = await socket.nextPrompt();
    expect(asked).toEqual([CHAT]);
    expect(prompt.params.prompt).toEqual([]);
    expect(promptMeta(prompt)).toMatchObject({
      acpmux: { promptId: "handoff-7-resume-cloud" },
      cmuxGesture: "cloud-ticket",
    });
    socket.accept(prompt);
    expect(client.swapHold()).toBeNull();
    socket.reply(prompt, { stopReason: "end_turn" });
    await resumed;
  } finally {
    client.close();
  }
});

test("a refused Cloud Resume leaves its handoff turn available to a new Resume", async () => {
  const { client, socket, snapshots } = await connect();
  const asked: string[] = [];
  client.handoffTurn = async (sessionId) => {
    asked.push(sessionId);
    return 7;
  };
  try {
    const first = client
      .resumeInterrupted(CHAT, "resume-cloud-refused", "first-ticket")
      .catch((error: unknown) => error);
    const refused = await socket.nextPrompt();
    expect(promptMeta(refused).acpmux.promptId).toBe("handoff-7-resume-cloud-refused");
    socket.refuse(refused);
    expect(await first).toMatchObject({ message: "Resume was refused" });
    expect(client.swapHold()).toBeNull();
    expect(snapshots.flatMap((snapshot) => snapshot.rows).filter((row) => row.kind === "user")).toEqual([]);

    const second = client
      .resumeInterrupted(CHAT, "resume-cloud-again", "second-ticket")
      .catch((error: unknown) => error);
    const retried = await socket.nextPrompt(1);
    expect(asked).toEqual([CHAT, CHAT]);
    expect(retried.params.prompt).toEqual([]);
    expect(promptMeta(retried)).toMatchObject({
      acpmux: { promptId: "handoff-7-resume-cloud-again" },
      cmuxGesture: "second-ticket",
    });
    socket.accept(retried);
    expect(client.swapHold()).toBeNull();
    socket.reply(retried, { stopReason: "end_turn" });
    expect(await second).toBe(CHAT);
    expect(snapshots.flatMap((snapshot) => snapshot.rows).filter((row) => row.kind === "user")).toEqual([]);
  } finally {
    client.close();
  }
});

for (const [reason, change] of [
  ["another pane starts work", { status: "running" }],
  ["the harness changes", { harness: "claude", family: "claude" }],
] as const) {
  test(`Resume refuses stale empty input when ${reason} in the same chat during a Cloud handoff`, async () => {
    const { client, socket, snapshots } = await connect();
    let entered!: () => void;
    let release!: (turn: number) => void;
    const handoffStarted = new Promise<void>((resolve) => (entered = resolve));
    client.handoffTurn = () => {
      entered();
      return new Promise<number>((resolve) => (release = resolve));
    };
    const selection = client.selectionToken;
    try {
      // If the fence fails, finish the unexpected request so the assertion reports the dispatch
      // rather than leaving the fake daemon's turn pending until the test times out.
      socket.autoReplyPrompts = true;
      const stale = client.resumeInterrupted(CHAT, "resume-stale", "stale-ticket").then(
        () => "sent",
        () => "refused",
      );
      await handoffStarted;
      socket.sessionChanged({ ...change, updatedAt: 2 });
      release(7);
      expect(await stale).toBe("refused");
      expect(client.selectedSession).toBe(CHAT);
      expect(client.selectionToken).toBe(selection);
      expect(socket.sent.filter((request) => request.method === "session/prompt")).toEqual([]);
      expect(client.swapHold()).toBeNull();
      expect(snapshots.flatMap((snapshot) => snapshot.rows).filter((row) => row.kind === "user")).toEqual([]);

      socket.autoReplyPrompts = false;
      socket.sessionChanged({ status: "idle", updatedAt: 3 });
      client.handoffTurn = async () => 7;
      const next = client.resumeInterrupted(CHAT, "resume-current", "current-ticket").catch((error: unknown) => error);
      const prompt = await socket.nextPrompt();
      expect(promptMeta(prompt).acpmux.promptId).toBe("handoff-7-resume-current");
      expect(prompt.params.prompt).toEqual([]);
      socket.accept(prompt);
      socket.reply(prompt, { stopReason: "end_turn" });
      expect(await next).toBe(CHAT);
      expect(client.swapHold()).toBeNull();
    } finally {
      client.close();
    }
  });
}

test("a fence invalidated after the Cloud claim releases that turn before a new Resume", async () => {
  let observedClient: AcpmuxDirectClient | undefined;
  let armed = false;
  let current = true;
  let invalidatedClaim: number | undefined;
  const { client, socket, snapshots } = await connect(undefined, () => {
    if (!armed || !observedClient) return;
    // Observe the claim only to place the race: the retry's wire identity below verifies cleanup.
    const claimed = (observedClient as unknown as { handoffTurnsSent: Map<string, number> }).handoffTurnsSent.get(CHAT);
    if (claimed !== 7) return;
    invalidatedClaim = claimed;
    current = false;
    armed = false;
  });
  observedClient = client;
  client.handoffTurn = async () => 7;
  try {
    socket.autoReplyPrompts = true;
    armed = true;
    const stale = await client
      .resumeInterrupted(CHAT, "resume-after-claim", "stale-ticket", () => current)
      .catch((error: unknown) => error);
    expect(invalidatedClaim).toBe(7);
    expect(stale).toBeInstanceOf(Error);
    expect(socket.sent.filter((request) => request.method === "session/prompt")).toEqual([]);
    expect(client.swapHold()).toBeNull();
    expect(snapshots.flatMap((snapshot) => snapshot.rows).filter((row) => row.kind === "user")).toEqual([]);

    socket.autoReplyPrompts = false;
    current = true;
    const resumed = client
      .resumeInterrupted(CHAT, "resume-after-claim-again", "current-ticket", () => current)
      .catch((error: unknown) => error);
    const prompt = await socket.nextPrompt();
    expect(promptMeta(prompt)).toMatchObject({
      acpmux: { promptId: "handoff-7-resume-after-claim-again" },
      cmuxGesture: "current-ticket",
    });
    expect(stale).toMatchObject({ code: "transport.continuation_changed" });
    expect(prompt.params.prompt).toEqual([]);
    socket.accept(prompt);
    socket.reply(prompt, { stopReason: "end_turn" });
    expect(await resumed).toBe(CHAT);
    expect(client.swapHold()).toBeNull();
  } finally {
    client.close();
  }
});

test("an unreviewed continuation blocks Resume before a prompt or Cloud turn is dispatched", async () => {
  const enforcement = { policy: "default", label: "native_policy", isolation: "unverified", detail: null } as const;
  const handoff: Handoff = {
    handoffId: "handoff-review",
    handoffKey: "review-key",
    state: "draft",
    revision: 1,
    source: {
      sessionId: "source-chat",
      harness: "claude",
      cwd: "/home/dev/project",
      coverage: [],
      enforcement,
      seq: 1,
    },
    target: { sessionId: CHAT, harness: "codex", cwd: "/home/dev/project", coverage: [], enforcement },
    capsule: {
      text: "Review this continuation first.",
      maxBytes: 65536,
      context: { fromSeq: 0, toSeq: 1, truncated: false, bytes: 31, totalBytes: 31 },
      checkpoint: null,
      memoryRefs: [],
    },
    promptId: null,
    turnId: null,
    createdAt: "2026-11-13T00:00:00Z",
    updatedAt: "2026-11-13T00:00:00Z",
  };
  const { client, socket, snapshots } = await connect(handoff);
  const asked: string[] = [];
  client.handoffTurn = async (sessionId) => {
    asked.push(sessionId);
    return 8;
  };
  try {
    await expect(client.resumeInterrupted(CHAT, "resume-unreviewed", "ticket")).rejects.toThrow(
      translate("error.reviewContinuation"),
    );
    expect(socket.sent.some((request) => request.method === HANDOFF_OPS.get)).toBe(true);
    expect(client.handoff.state.record?.handoffId).toBe(handoff.handoffId);
    expect(socket.sent.filter((request) => request.method === "session/prompt")).toEqual([]);
    expect(asked).toEqual([]);
    expect(client.swapHold()).toBeNull();
    expect(snapshots.flatMap((snapshot) => snapshot.rows).filter((row) => row.kind === "user")).toEqual([]);
  } finally {
    client.close();
  }
});
