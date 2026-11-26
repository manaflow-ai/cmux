// A streaming reply sends a snapshot every display frame. The copy kept for a reload of the page
// (sessionStorage "cmux.acpmux.snapshot") is the whole transcript as JSON, so writing it on every
// one took main-thread time that grew with the chat: it is written at most every 250 ms, with the
// latest snapshot, and at once when the page hides or unloads.
import { afterAll, expect, jest, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import { settleReact } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const writes: string[] = [];
const store = { quota: Infinity, removed: 0 };
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
    setItem: (key: string, value: string) => {
      if (value.length > store.quota) throw new Error("QuotaExceededError");
      if (key === "cmux.acpmux.snapshot") writes.push(value);
    },
    removeItem: () => void (store.removed += 1),
  },
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const { saveSnapshot, savedSessions, turnEndedBetween, SAVED_ROWS, SAVED_BYTES } =
  await import("../src/agent-session/acpmux/snapshotCache");

afterAll(async () => {
  await settleReact();
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

// A long live chat streamed with its whole transcript serialized every 250 ms: 20,000 rows were
// 5 MB and milliseconds of main thread per write, and past the store's quota the write failed and
// left a stale copy. The copy is a first paint, so it keeps the newest rows: its cost and size are
// the same at 2,000 rows and at 20,000.
const longChat = (count: number, text = "a line of a reply that is about this long, with words ".repeat(3)) =>
  ({
    ...snapshot(""),
    rows: Array.from({ length: count }, (_, n) => ({ id: `row-${n}`, kind: n % 2 ? "assistant" : "user", text })),
    historyFrom: 1,
    canLoadOlder: false,
  }) as unknown as AcpmuxSnapshot;
const writeTimed = (next: AcpmuxSnapshot) => {
  writes.length = 0;
  saveSnapshot(next);
  const start = performance.now();
  dom.window.dispatchEvent(new dom.window.Event("pagehide"));
  return { ms: performance.now() - start, value: writes.at(-1)! };
};
const median = (count: number) => {
  const next = longChat(count);
  const runs = Array.from({ length: 15 }, () => writeTimed(next));
  return { ms: runs.map((run) => run.ms).sort((a, b) => a - b)[7]!, value: runs[0]!.value };
};

test("the reload copy's write cost and size stay flat from 2,000 to 20,000 rows", () => {
  const small = median(2_000);
  const large = median(20_000);
  console.log(
    `reload copy: 2k rows ${small.ms.toFixed(3)} ms ${small.value.length} B; 20k rows ${large.ms.toFixed(3)} ms ${large.value.length} B`,
  );
  expect(large.value.length).toBeLessThan(small.value.length * 1.1);
  expect(large.value.length).toBeLessThan(SAVED_BYTES);
  // Generous for a loaded runner: the whole transcript took ten times the small write.
  expect(large.ms).toBeLessThan(Math.max(small.ms * 3, 1));
});

test("a restored copy paints the newest rows and says older history is left", async () => {
  const { cachedSnapshot } = await import("../src/agent-session/acpmux/snapshotCache");
  const { value } = writeTimed(longChat(20_000));
  const had = scope.sessionStorage;
  scope.sessionStorage = { getItem: () => value, setItem: () => {}, removeItem: () => {} };
  try {
    const restored = cachedSnapshot();
    expect(restored.rows.length).toBe(SAVED_ROWS);
    expect(restored.rows.at(-1)!.id).toBe("row-19999");
    expect(restored.rows[0]!.id).toBe(`row-${20_000 - SAVED_ROWS}`);
    expect(restored.canLoadOlder).toBe(true);
    expect(restored.historyFrom).toBeUndefined();
  } finally {
    scope.sessionStorage = had;
  }
  // A chat that fits whole is saved whole.
  const whole = JSON.parse(writeTimed(longChat(20)).value);
  expect(whole.rows.length).toBe(20);
  expect(whole.canLoadOlder).toBe(false);
});

test("a full store keeps a smaller newest tail, and a copy that fits nowhere is removed", () => {
  writes.length = 0;
  // Rows of pasted text: 200 of them are past the byte bound, and the store takes 100 KB.
  store.quota = 100_000;
  try {
    const { value } = writeTimed(longChat(5_000, "pasted ".repeat(1_000)));
    const kept = JSON.parse(value).rows as { id: string }[];
    expect(value.length).toBeLessThanOrEqual(100_000);
    expect(kept.length).toBeGreaterThan(0);
    expect(kept.at(-1)!.id).toBe("row-4999");
    store.quota = 10;
    store.removed = 0;
    writeTimed(longChat(5_000));
    expect(writes.length).toBe(0);
    expect(store.removed).toBe(1);
  } finally {
    store.quota = Infinity;
  }
});

test("rows each past the byte bound save no rows, never the whole transcript", () => {
  // The newest 3 rows are already past SAVED_BYTES, so the last try keeps none: slice(-0) is every row.
  const { value } = writeTimed(longChat(40, "x".repeat(SAVED_BYTES / 2)));
  expect(value.length).toBeLessThan(SAVED_BYTES);
  const saved = JSON.parse(value);
  expect(saved.rows.length).toBe(0);
  expect(saved.canLoadOlder).toBe(true);
});

// Last: a cleared page keeps no copy for the rest of its life.
test("clearSnapshot drops a pending write and later saves (a pane failure)", async () => {
  const { clearSnapshot } = await import("../src/agent-session/acpmux/snapshotCache");
  writes.length = 0;
  store.removed = 0;
  saveSnapshot(longChat(3));
  clearSnapshot();
  expect(store.removed).toBe(1);
  saveSnapshot(longChat(3));
  // The page hides: a save that was kept would be written now.
  dom.window.dispatchEvent(new dom.window.Event("pagehide"));
  expect(writes.length).toBe(0);
});
