// A prompt whose connection went before acpmux answered it (user, 2026-10-30: a Claude chat stuck
// on "Still sending", its last prompts drawn twice in one bubble). The app makes a new client on the
// next connection (App.tsx connectHost); that client reads the chat from acpmux's attach, where
// acpmux's echo of the prompt is the prompt's one row: never a second, pending copy of it.
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
  const deadline = performance.now() + 2_000;
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
  delivery?: { state: string; promptId: string };
};
type Hooks = { answer: (method: string, params: any) => Promise<unknown> };

test("a prompt lost with its connection shows once, settled, in the next connection's chat", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  let sent: any;
  let first: InstanceType<typeof MockAcpmuxSocket> | undefined;
  // The first connection takes the prompt and never answers, then goes (the daemon or the app's
  // transport closed it).
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
  let rows1: Row[] = [];
  const one = await AcpmuxDirectClient.connect(
    mockHost,
    (s) => (rows1 = s.rows as Row[]),
    undefined,
    () => (first = new Silent()) as unknown as WebSocket,
  );
  const outcome = one.send("ship it").then(
    () => "sent",
    () => "lost",
  );
  await settle(() => sent !== undefined && rows1.some((row) => row.text === "ship it"));
  const promptId = sent._meta.acpmux.promptId as string;
  const sessionId = sent.sessionId as string;
  first!.close();
  (first as unknown as { onclose: (() => void) | null }).onclose?.();
  expect(await outcome).toBe("lost");
  one.close?.();

  // The next connection: acpmux ran the prompt (the host's journal sent it again under its id), so
  // the chat's log holds its echo.
  class Ran extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const hooks = this as unknown as Hooks;
      const answer = hooks.answer.bind(this);
      hooks.answer = async (method, params) => {
        const result = (await answer(method, params)) as any;
        if (method !== "_acpmux/attach" || params.sessionId !== sessionId) return result;
        const seq = Number(result.lastSeq ?? 0) + 1;
        const echo = {
          seq,
          sessionId,
          at: Date.now(),
          dir: "mux",
          kind: "user_message",
          msg: { text: "ship it", promptId, turnId: "t-ran", client: "cmux-react-agent-pane#x" },
        };
        return { ...result, events: [...(result.events ?? []), echo], lastSeq: seq };
      };
    }
  }
  let rows2: Row[] = [];
  const two = await AcpmuxDirectClient.connect(
    { ...mockHost, sessionId },
    (s) => (rows2 = s.rows as Row[]),
    undefined,
    () => new Ran() as unknown as WebSocket,
  );
  try {
    await settle(() => rows2.some((row) => row.kind === "user" && row.text === "ship it"));
    const copies = rows2.filter((row) => row.kind === "user" && (row.text ?? "").includes("ship it"));
    expect(copies.length).toBe(1);
    expect(copies[0]!.text).toBe("ship it");
    expect(copies[0]!.pending).toBeFalsy();
    expect(copies[0]!.delivery?.state ?? "settled").not.toBe("sending");
  } finally {
    two.close?.();
  }
});
