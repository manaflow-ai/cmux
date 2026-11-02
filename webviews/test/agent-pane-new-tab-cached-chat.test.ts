// l10n-allow-file: test fixture prompts, replies and titles, not shipped UI.
//
// A chat is instant when it is cached, in a NEW TAB as well as in the tab that read it (Leo
// 2026-10-20: a chat "should be instant if cached"). A pane's page keeps the tails of the chats it
// read (direct.ts `keptTails`), which is all a switch inside one pane needs; a new tab is a new
// page and keeps none, so every page hands its tails to the app host and asks the host for one
// before it attaches (tailCache.ts, AgentPaneTailCache.swift). The host holds them in memory only.
// These hold the page to that:
//
//   - a new page draws the chat the host kept, before its own attach answers;
//   - a new page with nothing kept waits for acpmux, and draws the chat it answers;
//   - the tail handed over is bounded in bytes, and a cut tail still offers the older turns it
//     cut (a tail that claimed a whole transcript would hide them, which is the bug of
//     test/reopened-chat-history.test.ts);
//   - a chat whose attach fails is dropped here and in the host, so no later tab draws it;
//   - what the host answers is read defensively: anything but a page tail opens the chat cold.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { readFile } from "node:fs/promises";
import { JSDOM } from "jsdom";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import { resetKeptTailsForTests } from "../src/agent-session/acpmux/tailCache";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";

const START = Date.UTC(2026, 9, 21, 9, 0, 0);
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

type Message = { id?: number; method: string; params?: Record<string, unknown> };
type Step = [dir: string, kind: string, msg: Record<string, unknown>];
type Page = { events: Step[]; from?: number; hasMore?: boolean };

const events = (sessionId: string, page: Page) =>
  page.events.map(([dir, kind, msg], at) => {
    const seq = (page.from ?? 1) + at;
    return { sessionId, seq, at: START + seq * 1000, dir, kind, msg };
  });

const prompt = (text: string): Step => ["mux", "user_message", { text }];
const reply = (sessionId: string, text: string): Step => [
  "in",
  "agent_message_chunk",
  {
    method: "session/update",
    params: { sessionId, update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } },
  },
];

/// acpmux for two chats, answering the pages its fixture holds. One per page of the pane: a
/// daemon owns the socket's callbacks, so two live clients on one would take each other's answers.
/// `hold` keeps the next attach of a chat unanswered, and `fail` refuses it.
class Daemon {
  readyState = 0;
  onopen: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onclose: (() => void) | null = null;
  onmessage: ((message: { data: string }) => void) | null = null;
  hold?: string;
  fail?: string;
  private held?: Message;
  private holding?: () => void;
  /** Resolves when the held attach has been asked for. */
  asked = new Promise<void>((resolve) => (this.holding = resolve));

  constructor(
    readonly sessionA: string,
    readonly sessionB: string,
    readonly pages: Map<string, Page>,
  ) {
    queueMicrotask(() => {
      this.readyState = 1;
      this.onopen?.();
    });
  }

  send(raw: string): void {
    const message = JSON.parse(raw) as Message;
    if (message.id === undefined) return;
    const sessionId = String(message.params?.sessionId ?? "");
    if (message.method === "_acpmux/attach" && sessionId === this.hold) {
      this.held = message;
      this.hold = undefined;
      this.holding?.();
      return;
    }
    queueMicrotask(() => this.answer(message));
  }

  close(): void {
    this.readyState = 3;
  }

  /** Answers the attach held back, as acpmux would once it caught up. */
  release(): void {
    const message = this.held;
    this.held = undefined;
    this.asked = new Promise<void>((resolve) => (this.holding = resolve));
    if (message) this.answer(message);
  }

  private summary(sessionId: string) {
    return {
      sessionId,
      cwd: "/home/dev/project",
      title: `Chat ${sessionId}`,
      harness: "claude",
      status: "idle",
      turnCount: 1,
      updatedAt: START,
    };
  }

  private answer(message: Message): void {
    const sessionId = String(message.params?.sessionId ?? "");
    if (message.method === "_acpmux/attach" && sessionId === this.fail) {
      this.fail = undefined;
      this.onmessage?.({
        data: JSON.stringify({ jsonrpc: "2.0", id: message.id, error: { code: -32603, message: "unavailable" } }),
      });
      return;
    }
    let result: unknown = {};
    if (message.method === "initialize")
      result = { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
    else if (message.method === "_acpmux/watch")
      result = { sessions: [this.summary(this.sessionA), this.summary(this.sessionB)] };
    else if (message.method === "_acpmux/attach") {
      const page = this.pages.get(sessionId) ?? { events: [] };
      const records = events(sessionId, page);
      result = {
        session: this.summary(sessionId),
        lastSeq: records.at(-1)?.seq ?? 0,
        events: records,
        hasMore: page.hasMore === true,
      };
    } else if (message.method === "_acpmux/events") {
      result = { events: [], hasMore: false, lastSeq: 0 };
    }
    this.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result }) });
  }
}

/// The app host's store, as ``AgentPaneTailCache`` holds it: the most recent chats, in memory, a
/// tail of at most 400 records each, and one refused whole rather than cut (a cut tail that still
/// called its history exhausted would hide the chat's older turns).
class Host {
  static readonly CHATS = 8;
  static readonly EVENTS = 400;
  readonly tails = new Map<string, any>();
  /// Every tail handed over, in order, for what the page chose to send.
  readonly wrote: { sessionId: string; events: number; bytes: number; historyExhausted: boolean }[] = [];
  /// Answers this instead of a kept tail, for a host that serves something else.
  answers?: () => unknown;

  install(): void {
    (
      dom.window as unknown as { cmuxAcpmuxActions: Record<string, (params: any) => Promise<unknown>> }
    ).cmuxAcpmuxActions = {
      "chat.tail.get": async (params: any) =>
        this.answers ? this.answers() : (this.tails.get(String(params.sessionId)) ?? null),
      "chat.tail": async (params: any) => {
        const sessionId = String(params.sessionId);
        const tail = params.tail;
        const events: unknown[] = Array.isArray(tail?.events) ? tail.events : [];
        this.tails.delete(sessionId);
        if (events.length > 0 && events.length <= Host.EVENTS) {
          this.wrote.push({
            sessionId,
            events: events.length,
            bytes: JSON.stringify(tail).length,
            historyExhausted: tail.historyExhausted === true,
          });
          this.tails.set(sessionId, tail);
        }
        while (this.tails.size > Host.CHATS) this.tails.delete(this.tails.keys().next().value!);
        return null;
      },
    };
  }
}

/// Lets the page's fire-and-forget hand-over reach the host.
const flush = async () => {
  for (let pass = 0; pass < 8; pass += 1) await new Promise((resolve) => setTimeout(resolve, 0));
};

const text = (snapshot: AcpmuxSnapshot | undefined) =>
  (snapshot?.rows ?? [])
    .map((row) => JSON.stringify(row))
    .join(" ")
    .replace(/\s+/g, " ");

let live: AcpmuxDirectClient[] = [];
afterEach(() => {
  for (const client of live) client.close();
  live = [];
  delete (dom.window as unknown as { cmuxAcpmuxActions?: unknown }).cmuxAcpmuxActions;
  resetKeptTailsForTests();
});

/// One chat's fixture: the two chat ids, the pages acpmux answers for them, and the app host,
/// which outlives every page as the app outlives a tab. A page of the pane is a daemon and a
/// client; a NEW TAB is a new pair, holding no tails of its own, on the same host.
class Fixture {
  readonly a: string;
  readonly b: string;
  readonly pages = new Map<string, Page>();
  readonly host = new Host();

  constructor(name: string) {
    this.a = `${name}-a`;
    this.b = `${name}-b`;
    this.host.install();
  }

  /// A new tab on `sessionId`. The connect is not awaited: what the page draws *before* its attach
  /// answers is the point. `hold` keeps that attach unanswered; `fail` refuses it.
  ///
  /// A new tab is a new page, so the page's own tails start empty — which is what makes these
  /// tests about the host. `samePage` keeps them, for the one test that is about the page's map.
  tab(sessionId: string, options: { hold?: boolean; fail?: boolean; samePage?: boolean } = {}) {
    if (!options.samePage) resetKeptTailsForTests();
    const daemon = new Daemon(this.a, this.b, this.pages);
    if (options.hold) daemon.hold = sessionId;
    if (options.fail) daemon.fail = sessionId;
    const drawn: AcpmuxSnapshot[] = [];
    const client = AcpmuxDirectClient.connect(
      {
        protocolVersion: 1,
        transport: "acpmux-websocket",
        endpoint: "ws://new-tab.invalid/",
        token: "t",
        sessionId,
      },
      (snapshot) => {
        if (snapshot.type === "snapshot") drawn.push(snapshot);
      },
      undefined,
      () => daemon as unknown as WebSocket,
    );
    return { daemon, drawn, client, last: () => drawn.at(-1) };
  }

  /// Reads chat A in a tab of its own and leaves it, which is what hands its tail to the host, and
  /// closes that tab: one page of the pane at a time, as a daemon serves one client.
  async readInATab(): Promise<void> {
    const tab = this.tab(this.a);
    const client = await tab.client;
    await client.select(this.b);
    await flush();
    client.close();
  }
}

test("a chat opened in a new tab draws from the tail the host kept, before its own attach answers", async () => {
  const chat = new Fixture("new-tab");
  chat.pages.set(chat.a, { events: [prompt("Look at the retry path"), reply(chat.a, "Retry added.")] });
  chat.pages.set(chat.b, { events: [prompt("Docs"), reply(chat.b, "Docs updated.")] });
  await chat.readInATab();
  expect(chat.host.tails.has(chat.a)).toBe(true);

  // A new tab on the same chat, with acpmux slow to answer its attach.
  const tab = chat.tab(chat.a, { hold: true });
  await tab.daemon.asked;
  // The attach goes out with the chat list, before the host's tail is read: that read lands next.
  await flush();
  // Drawn from the host's tail, with this page's attach still in flight.
  expect(text(tab.last())).toContain("Retry added.");
  expect(tab.last()!.sessionId).toBe(chat.a);
  const beforeAttach = tab.drawn.length;
  tab.daemon.release();
  live.push(await tab.client);
  // And the attach lays what acpmux holds now over it: the same rows, nothing moved.
  expect(tab.drawn.length).toBeGreaterThan(beforeAttach);
  expect(text(tab.last())).toContain("Retry added.");
  // The whole transcript came over, so there is nothing older to offer.
  expect(tab.last()!.canLoadOlder).toBe(false);
});

/// The flow this cache is named for, which every other test here reaches the long way round: the
/// reader is on chat A and opens A in a new tab. The page keeps A selected, so A is never "left"
/// and `select` never hands it over — only the hand-over that `App.tsx` does before
/// `chat.openTab` (openOwnTab, onMoveToTab) puts A in the host. Without that call this test's
/// first expectation stays false and the new tab opens cold, which is the bug it holds.
test("opening the chat on screen in a new tab hands it over, with no switch away", async () => {
  const chat = new Fixture("open-own");
  chat.pages.set(chat.a, { events: [prompt("Look at the retry path"), reply(chat.a, "Retry added.")] });
  const read = chat.tab(chat.a);
  const client = await read.client;
  await flush();
  // Read, and still on screen: nothing has been handed over yet.
  expect(chat.host.tails.has(chat.a)).toBe(false);

  client.handOverCurrentTail();
  await flush();
  expect(chat.host.tails.has(chat.a)).toBe(true);
  client.close();

  // So the new tab draws the chat before its own attach answers, as it does for a chat left behind.
  // The connect is not awaited: with the attach held it never settles, and what is drawn before it
  // answers is the point.
  const tab = chat.tab(chat.a, { hold: true });
  await flush();
  expect(text(tab.last())).toContain("Retry added.");
  expect(tab.last()!.sessionId).toBe(chat.a);
});

/// The wiring the test above cannot reach. It calls `handOverCurrentTail` itself, so it proves the
/// client hands a chat over — not that anything in the product asks it to. The asking happens in
/// `App.tsx`, in the two actions that open a chat in a tab, and it is React code no test here
/// drives. Take either call away and every test in this file stays green while the flow this cache
/// is named for goes cold again, so the call sites are read out of the source.
///
/// Renaming the method is fine; this test then names what to rewrite it to.
test("the actions that open a chat in a tab hand the chat over first", async () => {
  const app = await readFile(new URL("../src/agent-session/acpmux/App.tsx", import.meta.url), "utf8");
  const sites = [...app.matchAll(/callNative\("chat\.openTab"/g)];
  // Two today (openOwnTab, onMoveToTab); a third would need the hand-over too, so this notices it.
  expect(sites.length).toBe(2);
  for (const site of sites) {
    // The hand-over has to come before the op, and close enough to belong to it.
    const before = app.slice(Math.max(0, site.index - 400), site.index);
    expect(
      before.includes("handOverCurrentTail()"),
      `a chat.openTab at index ${site.index} does not hand the chat over first, so the new tab ` +
        "opens cold (tailCache.ts). Call client.handOverCurrentTail() before it.",
    ).toBe(true);
  }
});

/// A subagent's pane is a tab on the chat's own session too (subagentPanes.ts), so the action that
/// asks the shared navigation helper for one supplies the hand-over callback. The helper's
/// behavioral tests check that it runs before the pane request, and only when a pane opens.
test("opening a subagent in its own pane hands the chat over first", async () => {
  const app = await readFile(new URL("../src/agent-session/acpmux/App.tsx", import.meta.url), "utf8");
  const sites = [...app.matchAll(/showSubagentIn\(callNative/g)];
  expect(sites.length).toBe(1);
  for (const site of sites) {
    const options = app.slice(site.index, site.index + 500);
    expect(
      /beforeOpen:\s*\(\)\s*=>\s*directClient\.current\?\.handOverCurrentTail\(\)/.test(options),
      "showSubagent does not supply the shared helper's tail-handoff callback, so the pane opens cold (tailCache.ts).",
    ).toBe(true);
  }
});

/// A tab closing on a chat leaves it warm too: the page is gone before anything else could hand it
/// over, so `close` does it (and `pagehide`, which no test here can fire).
test("a tab closed on a chat hands that chat over", async () => {
  const chat = new Fixture("closed-on");
  chat.pages.set(chat.a, { events: [prompt("Look at the retry path"), reply(chat.a, "Retry added.")] });
  const read = chat.tab(chat.a);
  const client = await read.client;
  await flush();
  expect(chat.host.tails.has(chat.a)).toBe(false);
  client.close();
  await flush();
  expect(chat.host.tails.has(chat.a)).toBe(true);
});

/// The hand-over on `close` goes to the app host ALONE, and not into this page's own map: the host's
/// copy is the one that outlives the page, and nothing should be left behind a client that is gone.
///
/// Where the host has the same tail this only costs the next client one in-process read. It matters
/// where there is no host to read back from, which is what this test arranges by taking the host
/// away: then the map would be the only copy, and a later client would draw rows it never attached
/// to and cannot stand behind.
///
/// This is not hypothetical. Writing the page's map on `close` turned
/// `test/agent-pane-turn-tokens.test.tsx` and `src/.../failedPromptRetry.test.ts` red: a chat that
/// reports no tokens showed 225,000 of them, and one failed prompt drew two bubbles, both from a
/// tail a closed client left behind. Those suites catch it by accident, so this holds it on purpose.
test("a closed client leaves its tail with the host alone, not in its own page", async () => {
  const chat = new Fixture("page-map");
  chat.pages.set(chat.a, { events: [prompt("Look at the retry path"), reply(chat.a, "Retry added.")] });
  const read = chat.tab(chat.a);
  const client = await read.client;
  await flush();
  client.close();
  await flush();
  // The host has it, which is the whole point of handing it over on close.
  expect(chat.host.tails.has(chat.a)).toBe(true);

  // With the host taken away (a page outside the app, the gallery, an older app), the only thing
  // that could still draw this chat is the page's own map — and it must hold nothing.
  delete (dom.window as unknown as { cmuxAcpmuxActions?: unknown }).cmuxAcpmuxActions;
  const tab = chat.tab(chat.a, { hold: true, samePage: true });
  await tab.daemon.asked;
  // The attach goes out with the chat list, before the host's tail is read: that read lands next.
  await flush();
  expect(text(tab.last())).not.toContain("Retry added.");
  tab.daemon.release();
  live.push(await tab.client);
  // acpmux's own page is what the chat shows, as it would on any cold open.
  expect(text(tab.last())).toContain("Retry added.");
});

test("a new tab the host kept nothing for waits for acpmux, and draws what it answers", async () => {
  const chat = new Fixture("cold-tab");
  chat.pages.set(chat.a, { events: [prompt("Look at the retry path"), reply(chat.a, "Retry added.")] });
  const tab = chat.tab(chat.a, { hold: true });
  await tab.daemon.asked;
  // The attach goes out with the chat list, before the host's tail is read: that read lands next.
  await flush();
  // Nothing was kept for this chat, so there is nothing to draw until acpmux answers: this is the
  // cold open the test above is measured against.
  expect(text(tab.last())).not.toContain("Retry added.");
  tab.daemon.release();
  live.push(await tab.client);
  expect(text(tab.last())).toContain("Retry added.");
});

/// The other half of "instant if cached" is the host's loading state. It covers a pane until the
/// page reports its first paint, and then fades its background out over the page in 120 ms
/// (`MotionFade.fadeIn`, AgentPaneView+Loading.swift), which Leo asked for on 2026-10-14 for a chat
/// the app had not loaded. A chat drawn from a kept tail is already on screen in that first frame,
/// so fading it in puts 120 ms of softness on the one open that is instant. The page is the only
/// side that knows which of the two it drew, so it says so in the snapshot the paint report reads.
test("a new tab that drew the host's tail says so, so its chat shows without the cold fade", async () => {
  const chat = new Fixture("no-fade");
  chat.pages.set(chat.a, { events: [prompt("Look at the retry path"), reply(chat.a, "Retry added.")] });
  chat.pages.set(chat.b, { events: [prompt("Docs"), reply(chat.b, "Docs updated.")] });
  await chat.readInATab();
  const tab = chat.tab(chat.a, { hold: true });
  await tab.daemon.asked;
  // The attach goes out with the chat list, before the host's tail is read: that read lands next.
  await flush();
  // The frame the open landed on drew the chat, and says where those rows came from.
  expect(text(tab.last())).toContain("Retry added.");
  expect(tab.last()!.drewKeptTail).toBe(true);
  tab.daemon.release();
  live.push(await tab.client);
  // Still true once the attach is in: the first frame is what the host's fade is about.
  expect(tab.last()!.drewKeptTail).toBe(true);
});

test("a new tab with nothing kept never claims a tail, so its chat keeps the cold fade", async () => {
  const chat = new Fixture("cold-fade");
  chat.pages.set(chat.a, { events: [prompt("Look at the retry path"), reply(chat.a, "Retry added.")] });
  const tab = chat.tab(chat.a, { hold: true });
  await tab.daemon.asked;
  // The attach goes out with the chat list, before the host's tail is read: that read lands next.
  await flush();
  // Nothing kept, so this page draws nothing at all until acpmux answers.
  expect(tab.last()?.drewKeptTail).toBeUndefined();
  tab.daemon.release();
  live.push(await tab.client);
  // acpmux's own page is this chat's first draw here, so the chat fades in as it did before.
  expect(text(tab.last())).toContain("Retry added.");
  expect(tab.last()?.drewKeptTail).toBeUndefined();
});

/// The report itself is React code no test here drives (as with the hand-over above): the client
/// can carry the fact and the host can act on it while the one call between them drops it, and
/// every other test in this file stays green. So the call site is read out of the source. The
/// Swift side holds the host to acting on it (`AgentPaneColdChatRevealTests`); this holds the one
/// call between them.
///
/// It reads the value, not only the word: a report that passed `drewKeptTail: false` outright, or
/// named the field in a comment, would leave every cached open fading while this stayed green.
/// Renaming the field is fine; this test then names what to rewrite it to.
test("the first-paint report tells the host whether the page drew a kept tail", async () => {
  const app = await readFile(new URL("../src/agent-session/acpmux/App.tsx", import.meta.url), "utf8");
  const sites = [...app.matchAll(/callNative\("pane\.painted"([^)]*)\)/g)];
  // One today, in the effect that runs on the frame the page first shows what it is. A second call
  // site would need the fact too, so this notices one rather than reading only the first.
  expect(sites.length).toBe(1);
  for (const site of sites) {
    // `{ drewKeptTail }`, or `drewKeptTail: <something that is not a constant>`. A literal false or
    // undefined is the bug this exists for, written out.
    const passed = /\bdrewKeptTail\b\s*(?:[,}]|:\s*(?!false\b|undefined\b|null\b)\S)/.test(site[1]!);
    expect(
      passed,
      "pane.painted does not carry a live drewKeptTail, so the host cannot tell a cached open from " +
        `a cold one and fades both (AgentPaneView+Loading.swift). Found: ${site[0]}`,
    ).toBe(true);
  }
});

test("the tail handed to the host is bounded in bytes, and what it cut it still offers", async () => {
  const chat = new Fixture("bounded");
  // Eight turns of 40 KB: more than the 256 KiB a tail may take to the host.
  const big = Array.from({ length: 8 }, (_, at) => [
    prompt(`Turn ${at + 1}: ${"x".repeat(40 * 1024)}`),
    reply(chat.a, `Turn ${at + 1} done.`),
  ]).flat();
  chat.pages.set(chat.a, { events: big });
  chat.pages.set(chat.b, { events: [prompt("Docs"), reply(chat.b, "Docs updated.")] });
  await chat.readInATab();

  // A's write, not simply the last one: closing that tab hands its chat on screen over too, so B's
  // is last.
  const wrote = chat.host.wrote.filter((write) => write.sessionId === chat.a).at(-1)!;
  expect(wrote.sessionId).toBe(chat.a);
  // Bounded: the newest records that fit, not the chat's sixteen.
  expect(wrote.events).toBeLessThan(big.length);
  expect(wrote.bytes).toBeLessThan(400 * 1024);
  // And a cut tail is not a whole transcript, whatever the page that cut it had read.
  expect(wrote.historyExhausted).toBe(false);

  const tab = chat.tab(chat.a, { hold: true });
  await tab.daemon.asked;
  // The attach goes out with the chat list, before the host's tail is read: that read lands next.
  await flush();
  expect(text(tab.last())).toContain("Turn 8 done.");
  // The turns the bound cut are still offered, instead of a transcript that claims to be whole.
  expect(tab.last()!.canLoadOlder).toBe(true);
  tab.daemon.release();
  live.push(await tab.client);
});

test("a chat whose attach fails is dropped here and in the host, so the next tab does not draw it", async () => {
  const chat = new Fixture("attach-fails");
  chat.pages.set(chat.a, { events: [prompt("Look at the retry path"), reply(chat.a, "Retry added.")] });
  chat.pages.set(chat.b, { events: [prompt("Docs"), reply(chat.b, "Docs updated.")] });
  await chat.readInATab();

  const tab = chat.tab(chat.a, { fail: true });
  await expect(tab.client).rejects.toThrow();
  await flush();
  // A tail this page could not stand behind is not left on screen, and not left for the next tab.
  expect(text(tab.last())).not.toContain("Retry added.");
  expect(chat.host.tails.has(chat.a)).toBe(false);
});

test("a host that answers something other than a tail leaves the chat to open cold", async () => {
  const chat = new Fixture("odd-host");
  chat.pages.set(chat.a, { events: [prompt("Look at the retry path"), reply(chat.a, "Retry added.")] });
  for (const answer of [
    () => "not a tail",
    () => ({ events: "no" }),
    () => ({ events: [] }),
    () => undefined,
    () => ({ events: [{ seq: 1 }] }),
  ]) {
    chat.host.answers = answer;
    const tab = chat.tab(chat.a, { hold: true });
    await tab.daemon.asked;
    // The attach goes out with the chat list, before the host's tail is read: that read lands next.
    await flush();
    expect(text(tab.last())).not.toContain("Retry added.");
    tab.daemon.release();
    const client = await tab.client;
    // Whatever the host said, acpmux's own page is what the chat shows.
    expect(text(tab.last())).toContain("Retry added.");
    client.close();
  }
});
