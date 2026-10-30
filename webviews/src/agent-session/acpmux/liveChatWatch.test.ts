// Opening a Claude Code or Codex chat that another app still runs (a terminal `claude --resume`)
// showed only "This chat is still open in another process" with Fork It and Open Anyway, over an
// empty pane: acpmux refuses to resume it there (`adopt.live`). "there's frequently nothing wrong
// with showing the same session but in two different places" (Leo, 2026-10-29). The pane now
// watches it (View Only: its transcript, following that app) and offers the same choice over it;
// a daemon or harness that cannot watch it still gets the choice alone.
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

const settle = async (done: () => boolean) => {
  for (let tries = 0; tries < 500 && !done(); tries += 1) await new Promise((resolve) => setTimeout(resolve, 0));
};

type Hooks = {
  answer: (method: string, params: any) => Promise<unknown>;
  deliver: (message: unknown) => void;
  sessions: Record<string, unknown>[];
};
type Snapshot = {
  sessionId?: string;
  liveChat?: { canFork: boolean };
  liveTakeOver?: { canFork: boolean };
  summary?: { watching?: string };
};

const agentSessionId = "11111111-2222-3333-4444-555555555555";
const adopt = { harness: "claude", agentSessionId };

/// A daemon where the chat runs in another process: a plain adopt is refused as `adopt.live`; a
/// watch (when `watches`) opens it View Only.
async function open(watches: boolean) {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const { newSessionSummary } = await import("./mockFixture");
  const asked: Record<string, unknown>[] = [];
  class LiveElsewhere extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const hooks = this as unknown as Hooks;
      const answer = hooks.answer.bind(this);
      hooks.answer = async (method, params) => {
        if (method !== "session/new") return answer(method, params);
        const asking = params._meta?.acpmux?.adopt ?? {};
        asked.push(asking);
        if (!asking.watch || !watches)
          throw Object.assign(new Error("claude session is open in another process"), {
            data: { reason: "adopt.live", details: { signal: "registry", pid: 4242, canFork: true } },
          });
        const watched = { ...newSessionSummary("watched-1", "~/code/cmux", Date.now()), watching: "claude" };
        hooks.sessions.push(watched);
        hooks.deliver({
          jsonrpc: "2.0",
          method: "_acpmux/session_changed",
          params: { kind: "created", session: watched },
        });
        return { sessionId: "watched-1", _meta: { acpmux: { agentSessionId } } };
      };
    }
  }
  let snapshot: Snapshot = {};
  const client = await AcpmuxDirectClient.connect(
    { ...mockHost, sessionId: undefined, newSession: true, adopt },
    (next) => (snapshot = next as Snapshot),
    undefined,
    () => new LiveElsewhere() as unknown as WebSocket,
  );
  return { client, asked, now: () => snapshot };
}

test("a chat another app runs opens View Only, with Fork It and Open Anyway over its transcript", async () => {
  const { client, asked, now } = await open(true);
  try {
    await settle(() => now().sessionId === "watched-1" && Boolean(now().liveTakeOver));
    expect(asked).toEqual([adopt, { ...adopt, watch: true }]);
    expect(now().sessionId).toBe("watched-1");
    expect(now().summary?.watching).toBe("claude");
    expect(now().liveTakeOver).toEqual({ canFork: true });
    expect(now().liveChat).toBeUndefined();
  } finally {
    client.close?.();
  }
});

test("a chat that cannot be watched still gets the choice", async () => {
  const { client, asked, now } = await open(false);
  try {
    await settle(() => Boolean(now().liveChat));
    expect(asked).toEqual([adopt, { ...adopt, watch: true }]);
    expect(now().liveChat).toEqual({ canFork: true });
  } finally {
    client.close?.();
  }
});
