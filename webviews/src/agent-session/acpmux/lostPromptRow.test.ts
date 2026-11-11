// Leo, 2026-11-11 (session 01a18a35): every message he sent reached its chat (acpmux recorded each
// within milliseconds), yet one drew as sent and, under it, "Not sent yet: the agent service is
// taking longer than usual to answer. Your message is kept." The pane's connection went while a
// steer's request was still open (a reset, or the pane's own stall recovery), so the send counted
// as lost: its row went, and when the next connection did not show it in time the text went back
// to the composer and a free line said "Not sent yet", while the chat, once its record came, showed
// it sent. Now the lost prompt stays one row on the next connection: on its way until acpmux's record
// lands on that same row, or failed on that row with Retry if it never does.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const had = { window: "window" in scope, document: "document" in scope };
const before = { window: scope.window, document: scope.document };
beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
afterAll(() => {
  for (const key of ["window", "document"] as const)
    if (had[key]) scope[key] = before[key];
    else delete scope[key];
});

const settle = async (done: () => boolean) => {
  const deadline = performance.now() + 3_000;
  while (!done()) {
    if (performance.now() > deadline) throw new Error(`timed out waiting for ${done.toString()}`);
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
};

type Row = {
  id: string;
  kind: string;
  text?: string;
  pending?: boolean;
  failed?: boolean;
  error?: string;
  delivery?: { state: string; promptId: string };
};
type Hooks = { answer: (method: string, params: any) => Promise<unknown>; deliver: (message: unknown) => void };

/// Sends a steer on a connection that takes it and never answers (its turn runs on), then drops.
async function loseSteer(text: string) {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  let sent: any;
  let socket: InstanceType<typeof MockAcpmuxSocket> | undefined;
  class Silent extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const hooks = this as unknown as Hooks;
      const answer = hooks.answer.bind(this);
      hooks.answer = (method, params) => {
        if (method !== "session/prompt") return answer(method, params);
        sent = params;
        return new Promise(() => undefined);
      };
    }
  }
  let rows: Row[] = [];
  const one = await AcpmuxDirectClient.connect(
    mockHost,
    (s) => (rows = s.rows as Row[]),
    undefined,
    () => (socket = new Silent()) as unknown as WebSocket,
  );
  const failure = one.send(text, [], undefined, undefined, undefined, true).then(
    () => undefined,
    (error: unknown) => error,
  );
  await settle(() => sent !== undefined && rows.some((row) => row.text === text));
  const promptId = sent._meta.acpmux.promptId as string;
  const sessionId = sent.sessionId as string;
  socket!.close();
  (socket as unknown as { onclose: (() => void) | null }).onclose?.();
  const error = (await failure) as object;
  one.close?.();
  // The connection went while the request was open: the lost path, whatever this host journals.
  Object.assign(error, { lostPrompt: { sessionId, promptId } });
  return { one, error, promptId, sessionId };
}

/// The next connection, whose attach does not hold the prompt yet.
async function nextConnection(sessionId: string, onPrompt?: (params: any) => void) {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  let daemon!: Hooks;
  class Plain extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      daemon = this as unknown as Hooks;
      const answer = daemon.answer.bind(this);
      daemon.answer = (method, params) => {
        if (method === "session/prompt") onPrompt?.(params);
        return answer(method, params);
      };
    }
  }
  const view = { rows: [] as Row[] };
  const two = await AcpmuxDirectClient.connect(
    { ...mockHost, sessionId },
    (s) => (view.rows = s.rows as Row[]),
    undefined,
    () => new Plain() as unknown as WebSocket,
  );
  return { two, daemon, view };
}

test("a steer lost while its turn runs: one row, on its way, then sent once its echo lands; no notice, nothing back", async () => {
  const { clientWaiter, keepLostPrompt } = await import("./lostPrompt");
  const { error, promptId, sessionId, one } = await loseSteer("use the cache dir");
  const { two, daemon, view } = await nextConnection(sessionId);
  const clients = clientWaiter<typeof two>();
  try {
    clients.connected(two);
    const outcome = keepLostPrompt(
      error,
      clients,
      one as unknown as typeof two,
      { input: "use the cache dir", attachments: [] },
      1_000,
      2_000,
    );
    // Meanwhile the prompt is its own row on its way, never gone and never a failure.
    await settle(() => view.rows.some((row) => row.kind === "user" && row.text === "use the cache dir"));
    const waiting = view.rows.filter((row) => row.kind === "user" && row.text === "use the cache dir");
    expect(waiting.length).toBe(1);
    expect(waiting[0]!.delivery?.state).toBe("sending");
    expect(waiting[0]!.failed).toBeFalsy();
    // acpmux's record of it comes on the new connection.
    const seq = Number((two as unknown as { lastSeq: number }).lastSeq) + 1;
    daemon.deliver({
      jsonrpc: "2.0",
      method: "_acpmux/event",
      params: {
        seq,
        sessionId,
        at: Date.now(),
        dir: "mux",
        kind: "user_message",
        msg: {
          text: "use the cache dir",
          promptId,
          steer: true,
          turnId: "t-running",
          client: "cmux-react-agent-pane#x",
        },
      },
    });
    // Shown: its sender gives nothing back to the composer and says nothing (App.tsx).
    expect(await outcome).toBe("shown");
    const copies = view.rows.filter((row) => row.kind === "user" && (row.text ?? "").includes("use the cache dir"));
    expect(copies.length).toBe(1);
    expect(copies[0]!.id).toBe(waiting[0]!.id);
    expect(copies[0]!.pending).toBeFalsy();
    expect(copies[0]!.failed).toBeFalsy();
    expect(copies[0]!.delivery?.state).not.toBe("sending");
    expect(view.rows.some((row) => row.kind === "notice")).toBe(false);
  } finally {
    two.close?.();
  }
});

test("a lost prompt that never shows fails on its own row, and Retry sends it under the same prompt id", async () => {
  const { clientWaiter, keepLostPrompt } = await import("./lostPrompt");
  const { translate } = await import("./i18n");
  const { error, promptId, sessionId, one } = await loseSteer("ship it");
  const asked: string[] = [];
  const { two, view } = await nextConnection(sessionId, (params) => asked.push(params?._meta?.acpmux?.promptId));
  const clients = clientWaiter<typeof two>();
  try {
    clients.connected(two);
    const outcome = await keepLostPrompt(
      error,
      clients,
      one as unknown as typeof two,
      { input: "ship it", attachments: [] },
      1_000,
      50,
    );
    expect(outcome).toBe("failed");
    const row = view.rows.find((candidate) => candidate.kind === "user" && candidate.text === "ship it");
    expect(row?.failed).toBe(true);
    expect(row?.error).toBe(translate("prompt.failure.hostAway"));
    // The mock chat holds prompts of its own: this prompt draws once.
    expect(view.rows.filter((candidate) => candidate.kind === "user" && candidate.text === "ship it").length).toBe(1);
    expect(view.rows.some((candidate) => candidate.kind === "notice")).toBe(false);
    void two.retryPrompt(row!.id).catch(() => undefined);
    await settle(() => asked.length > 0);
    expect(asked[0]).toBe(promptId);
  } finally {
    two.close?.();
  }
});
