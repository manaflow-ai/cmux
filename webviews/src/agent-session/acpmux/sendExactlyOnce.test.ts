// l10n-allow-file: test fixture prompts, not shipped UI.
// cmux#60478: the pane gets this app's agent service back on its own and the composer stays usable
// while it is away, so a prompt sent across an outage must reach acpmux exactly once:
//
// - typed while no client is connected (the page's actions are gone between connections): it waits
//   for the next client (sendWhenReady.ts `pageClientLink`) and goes once on it; before, the app
//   refused the `chat.send` it has no action for and the prompt went back to the composer unsent;
// - in flight when the connection closed: the page never sends it again itself. The host's prompt
//   journal (Swift `AgentPanePromptRelay`) resends it under the same promptId, acpmux's prompt
//   ledger (cmux-tui acpmux hub/prompt_ledger.rs; hub_integration/prompt_delivery.rs) answers that
//   copy `duplicate` and runs the prompt once, and the page draws one row for it.
//
// The fake daemon below keeps acpmux's rule: one run per promptId, a later copy is a duplicate.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { settleReact } from "../../../test/support/domTeardown";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const had = { window: "window" in scope, document: "document" in scope };
const before = { window: scope.window, document: scope.document };
beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
afterAll(async () => {
  await settleReact();
  for (const key of ["window", "document"] as const)
    if (had[key]) scope[key] = before[key];
    else delete scope[key];
});

// Bounded by turns of the event loop, not wall time: a loaded runner is slower, never red.
const settle = async (done: () => boolean) => {
  for (let turns = 0; !done(); turns += 1) {
    if (turns > 20_000) throw new Error(`never settled: ${done.toString()}`);
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
};

type Row = { id: string; kind: string; text?: string; failed?: boolean; delivery?: { state: string } };
type Hooks = { answer: (method: string, params: any) => Promise<unknown>; deliver: (message: unknown) => void };

/// acpmux's prompt ledger across connections and restarts: each promptId runs once.
function ledger() {
  const runs = new Map<string, number>();
  const frames = new Map<string, number>();
  return {
    runs,
    frames,
    /// A `session/prompt` frame with `promptId`: true when it runs, false for a duplicate.
    take(promptId: string): boolean {
      frames.set(promptId, (frames.get(promptId) ?? 0) + 1);
      if (runs.has(promptId)) return false;
      runs.set(promptId, 1);
      return true;
    },
  };
}

/// A connection to the ledger's daemon. `hang`: a prompt it takes is never answered (its turn runs on).
async function connection(book: ReturnType<typeof ledger>, options: { sessionId?: string; hang?: boolean } = {}) {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  let daemon!: Hooks;
  let socket: (InstanceType<typeof MockAcpmuxSocket> & { onclose: (() => void) | null }) | undefined;
  class Ledgered extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      daemon = this as unknown as Hooks;
      const answer = daemon.answer.bind(this);
      daemon.answer = (method, params) => {
        if (method !== "session/prompt") return answer(method, params);
        const promptId = String(params?._meta?.acpmux?.promptId);
        if (!book.take(promptId)) return Promise.resolve({ stopReason: "end_turn", duplicate: true });
        if (options.hang) return new Promise(() => undefined);
        return answer(method, params);
      };
    }
  }
  const view = { rows: [] as Row[] };
  const client = await AcpmuxDirectClient.connect(
    options.sessionId ? { ...mockHost, sessionId: options.sessionId } : mockHost,
    (snapshot) => (view.rows = snapshot.rows as Row[]),
    undefined,
    () => (socket = new Ledgered() as never) as unknown as WebSocket,
  );
  const drop = () => {
    socket!.close();
    socket!.onclose?.();
  };
  return { client, daemon: () => daemon, view, drop };
}

const userRows = (rows: Row[], text: string) => rows.filter((row) => row.kind === "user" && row.text === text);

test("a prompt typed while no client is connected waits, then goes once on the next client", async () => {
  const { callNative } = await import("./callNative");
  const { pageClientLink, sendsHeldForHost } = await import("./sendWhenReady");
  const book = ledger();
  const page = window as unknown as { cmuxAcpmuxActions?: Record<string, (params: any) => Promise<unknown>> };
  // The connection went: the pane removed the page's actions and looks for the next client.
  delete page.cmuxAcpmuxActions;
  pageClientLink.lost();
  let settled = false;
  const sent = callNative("chat.send", { text: "typed while down", attachments: [] }).then(
    () => (settled = true),
    (error: unknown) => {
      settled = true;
      throw error;
    },
  );
  await new Promise((resolve) => setTimeout(resolve, 0));
  // Held, not refused and not given back: the composer says "Sending when ready".
  expect(settled).toBe(false);
  expect(sendsHeldForHost.get()).toBe(true);
  const next = await connection(book);
  try {
    page.cmuxAcpmuxActions = {
      "chat.send": ({ text, attachments }) => next.client.send(String(text), attachments ?? []),
    };
    pageClientLink.back();
    await sent;
    expect(sendsHeldForHost.get()).toBe(false);
    await settle(() => userRows(next.view.rows, "typed while down").length > 0);
    expect([...book.frames.values()]).toEqual([1]);
    expect([...book.runs.values()]).toEqual([1]);
    expect(userRows(next.view.rows, "typed while down").length).toBe(1);
    expect(next.view.rows.some((row) => row.failed)).toBe(false);
  } finally {
    delete page.cmuxAcpmuxActions;
    next.client.close?.();
  }
});

test("a send waiting for the next client goes back to its composer when the pane itself closes", async () => {
  const { callNative } = await import("./callNative");
  const { pageClientLink, sendsHeldForHost } = await import("./sendWhenReady");
  delete (window as unknown as { cmuxAcpmuxActions?: unknown }).cmuxAcpmuxActions;
  pageClientLink.lost();
  const sent = callNative("chat.send", { text: "never sent" }).then(
    () => "sent",
    () => "back",
  );
  await new Promise((resolve) => setTimeout(resolve, 0));
  pageClientLink.ended();
  expect(await sent).toBe("back");
  expect(sendsHeldForHost.get()).toBe(false);
});

test("a prompt in flight when its connection closed runs once: the page sends no copy, acpmux dedupes the journal's", async () => {
  const { clientWaiter, keepLostPrompt } = await import("./lostPrompt");
  const book = ledger();
  const one = await connection(book, { hang: true });
  const failure = one.client.send("in flight at the drop", []).then(
    () => undefined,
    (error: unknown) => error as object,
  );
  await settle(() => book.frames.size === 1);
  const promptId = [...book.frames.keys()][0]!;
  const sessionId = one.client.selectedSession!;
  one.drop();
  const error = (await failure)!;
  one.client.close?.();
  // This Mac's acpmux journals the prompt; the mock connection is not marked local, so mark it as
  // the lost path does (direct.ts `journalsPrompts`).
  Object.assign(error, { lostPrompt: { sessionId, promptId } });
  const two = await connection(book, { sessionId });
  const clients = clientWaiter<typeof two.client>();
  try {
    clients.connected(two.client);
    const outcome = keepLostPrompt(
      error,
      clients,
      one.client as unknown as typeof two.client,
      { input: "in flight at the drop", attachments: [] },
      1_000,
      5_000,
    );
    await settle(() => userRows(two.view.rows, "in flight at the drop").length > 0);
    // The page drew it as one row on its way and sent nothing itself on the new connection.
    expect(book.frames.get(promptId)).toBe(1);
    // The host's journal sends it again under its promptId: acpmux already holds it, so the copy is
    // a duplicate and nothing runs twice.
    await two.daemon().answer("session/prompt", {
      sessionId,
      prompt: [{ type: "text", text: "in flight at the drop" }],
      _meta: { acpmux: { promptId } },
    });
    expect(book.frames.get(promptId)).toBe(2);
    expect(book.runs.get(promptId)).toBe(1);
    // acpmux's record of the one run lands on the waiting row.
    const seq = Number((two.client as unknown as { lastSeq: number }).lastSeq) + 1;
    two.daemon().deliver({
      jsonrpc: "2.0",
      method: "_acpmux/event",
      params: {
        seq,
        sessionId,
        at: Date.now(),
        dir: "mux",
        kind: "user_message",
        msg: { text: "in flight at the drop", promptId, turnId: "t-once", client: "cmux-react-agent-pane#x" },
      },
    });
    expect(await outcome).toBe("shown");
    const copies = userRows(two.view.rows, "in flight at the drop");
    expect(copies.length).toBe(1);
    expect(copies[0]!.failed).toBeFalsy();
    expect(book.runs.get(promptId)).toBe(1);
  } finally {
    two.client.close?.();
  }
});
