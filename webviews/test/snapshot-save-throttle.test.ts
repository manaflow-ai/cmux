// A streaming reply sends a snapshot every display frame. The copy kept for a reload of the page
// (sessionStorage "cmux.acpmux.snapshot") is the whole transcript as JSON, so writing it on every
// one took main-thread time that grew with the chat: it is written at most every 250 ms, with the
// latest snapshot, and at once when the page hides or unloads.
import { afterAll, expect, jest, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const writes: string[] = [];
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  customElements: dom.window.customElements,
  Node: dom.window.Node,
  MutationObserver: dom.window.MutationObserver,
  sessionStorage: {
    getItem: () => null,
    setItem: (key: string, value: string) => key === "cmux.acpmux.snapshot" && writes.push(value),
    removeItem: () => {},
  },
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const { saveSnapshot, savedSessions, turnEndedBetween } = await import("../src/agent-session/acpmux/App");

afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
  dom.window.close();
});

const snapshot = (text: string) =>
  ({
    type: "snapshot",
    protocolVersion: 1,
    rows: [{ id: "reply", kind: "assistant", text }],
    sessions: [],
  }) as unknown as AcpmuxSnapshot;

test("a frame's snapshots write the page's copy once, with the latest", () => {
  writes.length = 0;
  jest.useFakeTimers();
  try {
    // Sixty frames of a streaming reply.
    for (let frame = 1; frame <= 60; frame += 1) saveSnapshot(snapshot("word ".repeat(frame)));
    expect(writes.length).toBe(0);
    jest.advanceTimersByTime(249);
    expect(writes.length).toBe(0);
    jest.advanceTimersByTime(1);
  } finally {
    jest.useRealTimers();
  }
  expect(writes.length).toBe(1);
  expect(JSON.parse(writes[0]!).rows[0].text).toBe("word ".repeat(60));
});

test("hiding the page writes the latest snapshot at once", () => {
  writes.length = 0;
  saveSnapshot(snapshot("before the reload"));
  dom.window.dispatchEvent(new dom.window.Event("pagehide"));
  expect(writes.length).toBe(1);
  expect(JSON.parse(writes[0]!).rows[0].text).toBe("before the reload");
  // Nothing is left to write.
  dom.window.dispatchEvent(new dom.window.Event("pagehide"));
  expect(writes.length).toBe(1);
});

// Every pane's snapshot carries acpmux's whole session list: 3,055 chats on Leo's Mac
// (cmuxterm-hq#4878). Serialized whole on every write it went past sessionStorage's 5 MB, so the
// reload copy was lost after the work was done. The copy keeps the newest chats and the shown
// chat's own family; the live list replaces it once the watch reads it.
test("the reload copy keeps the newest chats and the shown chat's family, not the whole list", () => {
  writes.length = 0;
  const id = (n: number) => `0190a000-0000-7000-8000-${n.toString(16).padStart(12, "0")}`;
  const chat = (n: number, extra: Record<string, unknown> = {}) => ({
    sessionId: id(n),
    title: `Chat ${n} ${"about something long enough to look like a real title ".repeat(2)}`,
    cwd: `/Users/someone/Projects/repo-${n % 40}`,
    harness: "claude",
    status: "idle",
    activityAt: 1_000_000 + n,
    preview: "a line of the latest reply ".repeat(8),
    ...extra,
  });
  const sessions = Array.from({ length: 3055 }, (_, n) => chat(n));
  const shown = 7;
  sessions[shown] = chat(shown, { parentId: id(3) });
  sessions[11] = chat(11, { startedBy: id(shown) });
  sessions[12] = chat(12, { parentId: id(shown), side: true });
  saveSnapshot({ ...snapshot("a reply"), sessionId: id(shown), sessions } as unknown as AcpmuxSnapshot);
  dom.window.dispatchEvent(new dom.window.Event("pagehide"));
  expect(writes.length).toBe(1);
  const kept = JSON.parse(writes[0]!).sessions as { sessionId: string }[];
  const ids = new Set(kept.map((entry) => entry.sessionId));
  // The newest 200, plus the shown chat, its parent, its sub-session and its side chat.
  expect(kept.length).toBe(204);
  for (const n of [shown, 3, 11, 12, 3054, 2855]) expect(ids.has(id(n))).toBe(true);
  expect(ids.has(id(2854))).toBe(false);
  // The list keeps its order.
  expect(kept[0]!.sessionId).toBe(id(3));
  console.log(`reload copy: ${writes[0]!.length} bytes for ${sessions.length} chats`);
  expect(writes[0]!.length).toBeLessThan(400_000);
});

test("a streaming frame's list, a new array of the same entries, is not chosen again", () => {
  const id = (n: number) => `0190a000-0000-7000-8000-${n.toString(16).padStart(12, "0")}`;
  const sessions = Array.from({ length: 3055 }, (_, n) => ({ sessionId: id(n), activityAt: n }));
  const list = (entries: typeof sessions) => ({ ...snapshot("a reply"), sessionId: id(0), sessions: entries });
  const first = savedSessions(list([...sessions]) as unknown as AcpmuxSnapshot);
  // Each snapshot maps the list into a new array (direct.ts emitNow): same entries, same choice.
  expect(savedSessions(list([...sessions]) as unknown as AcpmuxSnapshot)).toBe(first);
  // A changed entry chooses again.
  const changed = [...sessions];
  changed[5] = { ...changed[5]!, activityAt: 10_000 };
  const next = savedSessions(list(changed) as unknown as AcpmuxSnapshot);
  expect(next).not.toBe(first);
  expect(next.some((entry) => entry.sessionId === id(5))).toBe(true);
});

// A turn's end asks the native tab for the chat's pull request again (App.tsx `pane.tabState`).
// React draws a hidden page's batch as one render, so a turn that started and ended in it read as
// idle to idle; the client's `turnsEnded` count says it ended.
test("a turn's end is seen across one render of its start and end", () => {
  const chat = "0190a000-0000-7000-8000-000000000001";
  const idle = { session: chat, working: false };
  expect(turnEndedBetween({ ...idle, working: true }, idle)).toBe(true);
  expect(turnEndedBetween({ ...idle, turnsEnded: 2 }, { ...idle, turnsEnded: 3 })).toBe(true);
  expect(turnEndedBetween({ ...idle, turnsEnded: 3 }, { ...idle, turnsEnded: 3 })).toBe(false);
  // A new client counts from 0: its first end is one, after an older client's five.
  expect(turnEndedBetween({ ...idle, turnsEnded: 5 }, { ...idle, turnsEnded: 0 })).toBe(false);
  expect(turnEndedBetween({ ...idle, turnsEnded: 0 }, { ...idle, turnsEnded: 1 })).toBe(true);
  // Switching away from a working chat is no turn end.
  expect(turnEndedBetween({ session: "other", working: true, turnsEnded: 1 }, { ...idle, turnsEnded: 2 })).toBe(false);
});
