// Opening a Claude Code or Codex chat that another app still runs (a terminal `claude --resume`)
// showed only "This chat is still open in another process" with Fork It and Open Anyway, over an
// empty pane: acpmux refuses to resume it there (`adopt.live`). "there's frequently nothing wrong
// with showing the same session but in two different places" (Leo, 2026-10-29). The pane now
// watches it (View Only: its transcript, following that app) and asks nothing on open: "the fact
// that it's asking me to fork while im inside an existing claude code chat is bad" (Leo,
// 2026-10-30). The same choice shows over it only once a reply or Take Over is refused as live; a
// daemon or harness that cannot watch it still gets the choice alone.
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
/// watch (when `watches`) opens it View Only, once `watchGate` lets it answer; a fork starts a new
/// chat. `adoptOnConnect`: the host names the chat (a new tab), else the test resumes it later.
async function open(
  watches: boolean,
  {
    watchGate,
    answerGate,
    attachGate,
    adoptGate,
    trustOnce = false,
    adoptOnConnect = true,
    saved = false,
  }: {
    watchGate?: Promise<void>;
    answerGate?: Promise<void>;
    attachGate?: Promise<void>;
    adoptGate?: Promise<void>;
    trustOnce?: boolean;
    adoptOnConnect?: boolean;
    saved?: boolean;
  } = {},
) {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const { newSessionSummary } = await import("./mockFixture");
  const asked: Record<string, unknown>[] = [];
  const methods: string[] = [];
  const killed: string[] = [];
  let trusted = false;
  let other = "";
  class LiveElsewhere extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const hooks = this as unknown as Hooks;
      const answer = hooks.answer.bind(this);
      const created = (sessionId: string, fields: Record<string, unknown> = {}) => {
        const session = { ...newSessionSummary(sessionId, "~/code/cmux", Date.now()), ...fields };
        hooks.sessions.push(session);
        hooks.deliver({ jsonrpc: "2.0", method: "_acpmux/session_changed", params: { kind: "created", session } });
      };
      if (!hooks.sessions.length) created("other-1");
      if (saved) created("watched-1", { watching: "claude", agentSessionId });
      other = String(hooks.sessions[0]!.sessionId);
      hooks.answer = async (method, params) => {
        methods.push(method);
        if (method === "_acpmux/kill") killed.push(String(params.sessionId));
        if (method === "_acpmux/attach" && params.sessionId === "fork-1") await attachGate;
        if (method === "_acpmux/watch_take_over" && params.ifLive) await answerGate;
        if (method === "_acpmux/watch_take_over" && !params.ifLive)
          throw Object.assign(new Error("claude session is open in another process"), {
            data: { reason: "adopt.live", details: { signal: "registry", pid: 4242, canFork: true } },
          });
        if (method !== "session/new") return answer(method, params);
        const asking = params._meta?.acpmux?.adopt ?? {};
        asked.push(asking);
        if (asking.ifLive === "fork" && trustOnce && !trusted) {
          trusted = true;
          throw Object.assign(new Error("trust this folder first"), {
            data: { reason: "trust.pending", cwd: "~/code/cmux" },
          });
        }
        if (asking.ifLive === "fork") {
          await answerGate;
          created("fork-1");
          return { sessionId: "fork-1" };
        }
        if (!asking.watch && !asking.ifLive) await adoptGate;
        if (!asking.watch || !watches)
          throw Object.assign(new Error("claude session is open in another process"), {
            data: { reason: "adopt.live", details: { signal: "registry", pid: 4242, canFork: true } },
          });
        await watchGate;
        created("watched-1", { watching: "claude", agentSessionId });
        return { sessionId: "watched-1", _meta: { acpmux: { agentSessionId } } };
      };
    }
  }
  let snapshot: Snapshot = {};
  const client = await AcpmuxDirectClient.connect(
    saved
      ? { ...mockHost, sessionId: "watched-1" }
      : { ...mockHost, sessionId: undefined, newSession: true, ...(adoptOnConnect ? { adopt } : {}) },
    (next) => (snapshot = next as Snapshot),
    undefined,
    () => new LiveElsewhere() as unknown as WebSocket,
  );
  return { client, asked, methods, killed, other: () => other, now: () => snapshot };
}

test("a chat another app runs opens View Only and asks nothing until a take over is refused", async () => {
  const { client, asked, now } = await open(true);
  try {
    await settle(() => now().sessionId === "watched-1" && now().summary?.watching === "claude");
    await settle(() => false);
    expect(asked).toEqual([adopt, { ...adopt, watch: true }]);
    expect(now().sessionId).toBe("watched-1");
    expect(now().liveTakeOver).toBeUndefined();
    expect(now().liveChat).toBeUndefined();
    expect(client.adopted).toBe("watched-1");
    // A reply (or Take Over) that acpmux refuses as live is when Fork It and Open Anyway show.
    expect(await client.takeOver()).toBe(false);
    await settle(() => Boolean(now().liveTakeOver));
    expect(now().liveTakeOver).toEqual({ canFork: true });
  } finally {
    client.close?.();
  }
});

/// The watched chat open, then a take over refused as live: the choice over it.
async function refused(client: { takeOver(): Promise<boolean> }, now: () => Snapshot) {
  await settle(() => now().sessionId === "watched-1" && now().summary?.watching === "claude");
  expect(await client.takeOver()).toBe(false);
  await settle(() => Boolean(now().liveTakeOver));
}

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

test("Fork It over the watched chat starts the fork at once, as the choice alone did", async () => {
  const { client, asked, methods, now } = await open(true);
  try {
    await refused(client, now);
    // The choice's buttons call the page's `chat.adoptLive`, which persists `adopted` as the tab's chat.
    await client.adoptLive("fork");
    await settle(() => now().sessionId === "fork-1");
    expect(asked.at(-1)).toEqual({ ...adopt, ifLive: "fork" });
    // Only the refused take over that showed the choice: Fork It itself forks, it takes nothing over.
    expect(methods.filter((method) => method === "_acpmux/watch_take_over")).toHaveLength(1);
    expect(now().sessionId).toBe("fork-1");
    expect(client.adopted).toBe("fork-1");
  } finally {
    client.close?.();
  }
});

test("a watch that answers after the person moved to another chat leaves that chat shown", async () => {
  let release = () => undefined as void;
  const watchGate = new Promise<void>((resolve) => (release = resolve));
  const { client, asked, other, now, killed } = await open(true, { watchGate, adoptOnConnect: false });
  try {
    const resumed = client.resume(adopt);
    await settle(() => asked.length === 2);
    await client.select(other());
    release();
    await resumed;
    await settle(() => false);
    expect(now().sessionId).toBe(other());
    expect(now().liveChat).toBeUndefined();
    expect(now().liveTakeOver).toBeUndefined();
    expect(client.adopted).toBeUndefined();
    // The watch stays: acpmux may have answered with another pane's watch of the same chat.
    expect(killed).toEqual([]);
  } finally {
    client.close?.();
  }
});

test("a reloaded pane's watched chat refused as live still forks at once from its own id", async () => {
  const { client, asked, methods, now } = await open(true, { saved: true });
  try {
    await refused(client, now);
    await client.adoptLive("fork");
    await settle(() => now().sessionId === "fork-1");
    expect(asked.at(-1)).toEqual({ harness: "claude", agentSessionId, ifLive: "fork" });
    expect(methods.filter((method) => method === "_acpmux/watch_take_over")).toHaveLength(1);
    expect(client.adopted).toBe("fork-1");
  } finally {
    client.close?.();
  }
});

test("Open Anyway over the watched chat takes it over and keeps it as the tab's chat", async () => {
  const { client, methods, now } = await open(true);
  try {
    await refused(client, now);
    const kept = persisted(client);
    await client.adoptLive("open");
    expect(methods.at(-1)).toBe("_acpmux/watch_take_over");
    expect(client.adopted).toBe("watched-1");
    expect(kept).toEqual(["watched-1"]);
    expect(now().liveTakeOver).toBeUndefined();
  } finally {
    client.close?.();
  }
});

/// The chat each choice leaves the tab on, as the host persists it (`onAdopted`).
function persisted(client: { onAdopted?: (sessionId: string) => void }): string[] {
  const kept: string[] = [];
  client.onAdopted = (sessionId) => kept.push(sessionId);
  return kept;
}

test("Fork It keeps the fork as the tab's chat, also when it is retried after Trust", async () => {
  const { client, now } = await open(true);
  try {
    await refused(client, now);
    const kept = persisted(client);
    await client.adoptLive("fork");
    await settle(() => now().sessionId === "fork-1");
    expect(kept).toEqual(["fork-1"]);
  } finally {
    client.close?.();
  }
});

for (const choice of ["fork", "open"] as const)
  test(`a ${choice} answered after the person moved to another chat leaves that chat shown and kept`, async () => {
    let release = () => undefined as void;
    const answerGate = new Promise<void>((resolve) => (release = resolve));
    const { client, other, now } = await open(true, { answerGate });
    try {
      await refused(client, now);
      const kept = persisted(client);
      const chosen = client.adoptLive(choice);
      await settle(() => false);
      await client.select(other());
      release();
      await chosen;
      await settle(() => false);
      expect(now().sessionId).toBe(other());
      expect(kept).toEqual([]);
    } finally {
      client.close?.();
    }
  });

test("an adopt is kept as the tab's only once the pane shows it", async () => {
  let release = () => undefined as void;
  const attachGate = new Promise<void>((resolve) => (release = resolve));
  const { client, methods, other, now } = await open(true, { attachGate });
  try {
    await refused(client, now);
    const kept = persisted(client);
    // The fork's attach is still out when the person moves on: the other chat is kept, not the fork.
    const forked = client.adoptLive("fork");
    await settle(
      () =>
        methods.includes("_acpmux/attach") &&
        methods.lastIndexOf("_acpmux/attach") > methods.lastIndexOf("session/new"),
    );
    const moved = client.select(other());
    release();
    await Promise.all([forked, moved]);
    await settle(() => false);
    expect(now().sessionId).toBe(other());
    expect(kept).not.toContain("fork-1");
  } finally {
    client.close?.();
  }
});

for (const watches of [true, false])
  test(`an adopt refused as live after the person moved on shows nothing for it (${watches ? "watchable" : "not watchable"})`, async () => {
    let release = () => undefined as void;
    const adoptGate = new Promise<void>((resolve) => (release = resolve));
    const { client, asked, other, now } = await open(watches, { adoptGate, adoptOnConnect: false });
    try {
      const resumed = client.resume(adopt);
      await settle(() => asked.length === 1);
      await client.select(other());
      release();
      await resumed;
      await settle(() => false);
      expect(asked).toEqual([adopt]);
      expect(now().sessionId).toBe(other());
      expect(now().liveChat).toBeUndefined();
      expect(now().liveTakeOver).toBeUndefined();
    } finally {
      client.close?.();
    }
  });

test("a fork waiting on Trust is not retried after the person moved to another chat", async () => {
  const { client, asked, other, now } = await open(true, { trustOnce: true });
  try {
    await refused(client, now);
    let again: (() => void) | undefined;
    client.onTrustRefused = (_refusal, retry) => (again = retry);
    const kept = persisted(client);
    await client.adoptLive("fork");
    await settle(() => again !== undefined);
    expect(again).toBeDefined();
    await client.select(other());
    again?.();
    await settle(() => false);
    expect(asked.filter((a) => a.ifLive === "fork")).toHaveLength(1);
    expect(now().sessionId).toBe(other());
    expect(kept).toEqual([]);
  } finally {
    client.close?.();
  }
});
