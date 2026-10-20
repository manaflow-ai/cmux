// l10n-allow-file: test fixtures, not shipped UI.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import { configureLabs } from "../src/agent-session/acpmux/labs";
import { WORKSPACE_CONTEXT } from "../src/agent-session/acpmux/workspaceContext";

const TAG = "<cmux-chat-capabilities-context>";
const clients: AcpmuxDirectClient[] = [];
beforeEach(() => configureLabs(undefined));
afterEach(() => {
  for (const client of clients.splice(0)) client.close();
  configureLabs(undefined);
});

/// Exercise the prompt metadata over the client's socket, without a server or a harness.
async function chat(workspaceContext = false, fresh = false, origin: string | undefined = "local") {
  let socket: any;
  const sessions = ["chat-1", "chat-2"].map((sessionId) => ({
    sessionId,
    harness: "claude",
    agentSessionId: undefined as string | undefined,
    cwd: "/tmp/project",
    title: "Chat",
    status: "idle",
    updatedAt: 1,
  }));
  const prompts: any[] = [];
  const pending: number[] = [];
  let hold = false;
  let refuse: boolean | string = false;
  let editOK = true;
  let removeOK = true;
  let seq = 0;
  const event = (kind: string, promptId: string) =>
    socket.onmessage?.({
      data: JSON.stringify({
        jsonrpc: "2.0",
        method: "_acpmux/event",
        params: {
          sessionId: "chat-1",
          seq: ++seq,
          at: 1,
          dir: "mux",
          kind,
          msg: { promptId, text: "Queued" },
        },
      }),
    });
  const reply = (id: number) =>
    socket.onmessage?.({
      data: JSON.stringify({
        jsonrpc: "2.0",
        id,
        ...(refuse
          ? {
              error: {
                code: -32602,
                message: "refused",
                data: { reason: typeof refuse === "string" ? refuse : undefined },
              },
            }
          : { result: null }),
      }),
    });
  const open = () => {
    socket = {
      readyState: 1,
      close() {},
      send(raw: string) {
        const { id, method, params } = JSON.parse(raw);
        if (method === "session/prompt") {
          prompts.push(params);
          if (hold) pending.push(id);
          else queueMicrotask(() => reply(id));
          return;
        }
        if (method === "session/new") sessions.push({ ...sessions[0]!, sessionId: "chat-new" });
        const result =
          method === "initialize"
            ? { protocolVersion: 1, _meta: { acpmux: { origin, extensions: [] } } }
            : method === "_acpmux/watch"
              ? { sessions }
              : method === "_acpmux/attach"
                ? {
                    session: sessions.find((session) => session.sessionId === params.sessionId),
                    lastSeq: 0,
                    events: [],
                  }
                : method === "session/new"
                  ? { sessionId: "chat-new" }
                  : method === "_acpmux/queue_remove"
                    ? { removed: removeOK }
                    : method === "_acpmux/queue_edit"
                      ? { ok: editOK }
                      : null;
        if (id !== undefined)
          queueMicrotask(() =>
            socket.onmessage?.({
              data: JSON.stringify({ jsonrpc: "2.0", id, result }),
            }),
          );
      },
    };
    queueMicrotask(() => socket.onopen?.());
    return socket as WebSocket;
  };
  const client = await AcpmuxDirectClient.connect(
    {
      protocolVersion: 1,
      transport: "acpmux-websocket",
      endpoint: "ws://127.0.0.1:1/",
      ...(fresh ? { newSession: true } : { sessionId: "chat-1" }),
      workspaceContext,
    },
    () => {},
    undefined,
    open,
  );
  clients.push(client);
  if (!fresh) await client.select("chat-1");
  return {
    client,
    prompts,
    sessions,
    hold: () => {
      hold = true;
    },
    refuse: (value: boolean | string) => {
      refuse = value;
    },
    editOK: (value: boolean) => {
      editOK = value;
    },
    removeOK: (value: boolean) => {
      removeOK = value;
    },
    removed: (promptId: string) => event("queue_removed", promptId),
    dequeued: (promptId: string) => event("dequeued", promptId),
    queued: (promptId: string) => event("queued", promptId),
    updated: (promptId: string) => event("queue_updated", promptId),
    finish: () => {
      for (const id of pending.splice(0)) reply(id);
    },
  };
}
const context = (prompt: any): string | undefined => prompt._meta.acpmux.context;

test("the first prompt teaches rendering, without changing the person's text", async () => {
  const { client, prompts } = await chat();
  await client.send("Explain a feedback loop");
  expect(context(prompts[0])).toContain(TAG);
  expect(prompts[0].prompt).toEqual([{ type: "text", text: "Explain a feedback loop" }]);
  expect(context(prompts[0])!.length).toBeLessThan(2000);
});

test("the first prompt of a new session carries the guide after session creation", async () => {
  const { client, prompts } = await chat(false, true);
  await client.send("Start here");
  expect(prompts[0].sessionId).toBe("chat-new");
  expect(context(prompts[0])).toContain(TAG);
  await client.send("Continue");
  expect(context(prompts[1])).toBeUndefined();
});

for (const lab of ["liveRender", "renderGuide"])
  test(`no guide with ${lab} off`, async () => {
    configureLabs({ labs: { [lab]: false } });
    const { client, prompts } = await chat();
    await client.send("Explain");
    expect(context(prompts[0])).toBeUndefined();
    configureLabs(undefined);
    await client.send("Now explain");
    expect(context(prompts[1])).toContain(TAG);
  });

test("later prompts and a reselected session do not repeat the guide", async () => {
  const { client, prompts } = await chat();
  await client.send("First");
  await client.send("Second");
  await client.select("chat-2");
  await client.send("Other session");
  await client.select("chat-1");
  await client.send("Back");
  expect(prompts.map((prompt) => context(prompt)?.includes(TAG) ?? false)).toEqual([
    true,
    false,
    true,
    false,
  ]);
});

test("workspace context and the guide share the existing hidden channel", async () => {
  const { client, prompts } = await chat(true);
  await client.send("Explain");
  expect(context(prompts[0])).toStartWith(WORKSPACE_CONTEXT);
  expect(context(prompts[0])).toContain(TAG);
  expect(new TextEncoder().encode(context(prompts[0])).length).toBeLessThanOrEqual(16 * 1024);
  await client.send("Again");
  expect(context(prompts[1])).toBeUndefined();
});

test("workspace context still sends with the guide off", async () => {
  configureLabs({ labs: { renderGuide: false } });
  const { client, prompts } = await chat(true);
  await client.send("Explain");
  expect(context(prompts[0])).toBe(WORKSPACE_CONTEXT);
});

test("steer-only prompts and slash commands leave the guide for a normal prompt", async () => {
  const { client, prompts } = await chat();
  await client.send("Steer", [], "steer-1", undefined, undefined, true);
  await client.send("  /help");
  await client.send("Explain");
  expect(context(prompts[0])).toBeUndefined();
  expect(context(prompts[1])).toBeUndefined();
  expect(context(prompts[2])).toContain(TAG);
});

test("a changed harness or agent gets the guide again, but learning its initial id does not", async () => {
  const { client, prompts, sessions } = await chat();
  await client.send("First");
  sessions[0]!.agentSessionId = "agent-1";
  await client.select("chat-1");
  await client.send("Agent id arrived");
  sessions[0]!.agentSessionId = "agent-2";
  await client.select("chat-1");
  await client.send("New agent");
  sessions[0]!.harness = "codex";
  await client.select("chat-1");
  await client.send("New harness");
  expect(prompts.map((prompt) => context(prompt)?.includes(TAG) ?? false)).toEqual([
    true,
    false,
    true,
    true,
  ]);
});

test("a prompt in flight reserves the guide until accepted", async () => {
  const daemon = await chat();
  daemon.hold();
  const first = daemon.client.send("First");
  const second = daemon.client.send("Second");
  const contexts = daemon.prompts.map(context);
  daemon.finish();
  await Promise.all([first, second]);
  expect(contexts[0]).toContain(TAG);
  expect(contexts[1]).toBeUndefined();
});

test("a refused prompt leaves both contexts available for retry", async () => {
  const daemon = await chat(true);
  daemon.refuse(true);
  await expect(daemon.client.send("Refused")).rejects.toThrow("refused");
  daemon.refuse(false);
  await daemon.client.send("Retry");
  expect(context(daemon.prompts[1])).toStartWith(WORKSPACE_CONTEXT);
  expect(context(daemon.prompts[1])).toContain(TAG);
});

test.each(["web", "remote", ""])("a %s origin sends without a render guide", async (origin) => {
  const { client, prompts } = await chat(false, false, origin);
  await client.send("Explain");
  expect(context(prompts[0])).toBeUndefined();
});

test("a guide-only origin refusal retries once without context and disables later guides", async () => {
  const daemon = await chat();
  daemon.refuse("context.origin_refused");
  // The socket refuses context, but accepts the retry's ordinary prompt.
  const send = daemon.client.send("Explain");
  queueMicrotask(() => daemon.refuse(false));
  await send;
  await daemon.client.select("chat-2");
  await daemon.client.send("Other chat");
  expect(daemon.prompts.map((prompt) => context(prompt)?.includes(TAG) ?? false)).toEqual([
    true,
    false,
    false,
  ]);
  expect(daemon.prompts[1].prompt).toEqual(daemon.prompts[0].prompt);
  expect(daemon.prompts[1]._meta.acpmux.promptId).toBe(daemon.prompts[0]._meta.acpmux.promptId);
});

test("a workspace context origin refusal does not retry without its context", async () => {
  const daemon = await chat(true);
  daemon.refuse("context.origin_refused");
  await expect(daemon.client.send("Explain")).rejects.toThrow("refused");
  expect(daemon.prompts).toHaveLength(1);
});

test("the guide-only origin retry is bounded when the ordinary prompt is also refused", async () => {
  const daemon = await chat();
  daemon.refuse("context.origin_refused");
  await expect(daemon.client.send("Explain")).rejects.toThrow("refused");
  expect(daemon.prompts).toHaveLength(2);
  expect(context(daemon.prompts[1])).toBeUndefined();
});

test("editing the queued guide prompt leaves the guide for the next send", async () => {
  const daemon = await chat();
  daemon.hold();
  const pending = daemon.client.send("First", [], "first");
  daemon.queued("first");
  await daemon.client.editQueued("other", { op: "update", text: "Other" });
  await daemon.client.editQueued("first", { op: "move", index: 0 });
  daemon.editOK(false);
  await daemon.client.editQueued("first", { op: "update", text: "Too late" });
  daemon.editOK(true);
  const unchanged = daemon.client.send("Still reserved");
  expect(context(daemon.prompts[1])).toBeUndefined();
  await daemon.client.editQueued("first", { op: "update", text: "Edited" });
  const next = daemon.client.send("Next");
  const nextContext = context(daemon.prompts[2]);
  daemon.finish();
  await Promise.all([pending, unchanged, next]);
  expect(nextContext).toContain(TAG);
});

test("another client's queue edit also releases the guide mark", async () => {
  const daemon = await chat();
  daemon.hold();
  const pending = daemon.client.send("First", [], "first");
  daemon.queued("first");
  daemon.updated("first");
  const next = daemon.client.send("Next");
  const nextContext = context(daemon.prompts[1]);
  daemon.finish();
  await Promise.all([pending, next]);
  expect(nextContext).toContain(TAG);
});

test("the guide advertises kit APIs only while available and keeps its compact contract", async () => {
  const { RENDER_GUIDE } = await import("../src/agent-session/acpmux/conversation/renderGuide");
  expect(RENDER_GUIDE.length).toBeLessThan(2000);
  const daemon = await chat();
  await daemon.client.send("Explain");
  expect(context(daemon.prompts[0])).toContain("cmux.chart(element");
  expect(context(daemon.prompts[0])).toContain("data-cmux-prompt");
  configureLabs({ labs: { renderKit: false } });
  await daemon.client.select("chat-2");
  await daemon.client.send("Explain again");
  expect(context(daemon.prompts[1])).not.toContain("cmux.chart");
  expect(context(daemon.prompts[1])).not.toContain("data-cmux-prompt");
  expect(context(daemon.prompts[1])).toContain("prefill(text)");
  for (const token of [
    "--cmux-text",
    "--cmux-muted",
    "--cmux-card",
    "--cmux-border",
    "--cmux-accent",
    "--cmux-font",
  ])
    expect(context(daemon.prompts[1])).toContain(token);
});

test("both guides teach that declined bridge calls reject", async () => {
  const { renderGuide } = await import("../src/agent-session/acpmux/conversation/renderGuide");
  for (const renderKit of [true, false]) {
    configureLabs({ labs: { renderKit } });
    expect(renderGuide()).toContain("reject when declined");
  }
});

test.each(["reply", "event"] as const)(
  "withdrawing a queued guide prompt releases it through the %s path",
  async (via) => {
    const daemon = await chat();
    daemon.hold();
    const first = daemon.client.send("First", [], "first");
    daemon.queued("first");
    if (via === "reply") await daemon.client.removeQueued("first");
    else daemon.removed("first");
    const next = daemon.client.send("Next");
    const nextContext = context(daemon.prompts[1]);
    daemon.finish();
    await Promise.all([first, next]);
    expect(nextContext).toContain(TAG);
  },
);

test("a refused removal, another prompt's removal and dequeue keep the delivered guide", async () => {
  const daemon = await chat();
  daemon.hold();
  const first = daemon.client.send("First", [], "first");
  daemon.queued("first");
  daemon.removeOK(false);
  await daemon.client.removeQueued("first");
  daemon.removed("other");
  daemon.dequeued("first");
  const next = daemon.client.send("Next");
  const nextContext = context(daemon.prompts[1]);
  daemon.finish();
  await Promise.all([first, next]);
  expect(nextContext).toBeUndefined();
});
