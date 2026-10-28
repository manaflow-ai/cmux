// Prompt bookmarks at the pane boundary: the thread minimap's popover bookmark reads and toggles the
// chat's marks in acpmux (`_acpmux/bookmark_get`, `_acpmux/bookmark_set`), so a mark survives a
// reload, a restart and a move, and shows in every pane on the chat. A toggle shows at once and is
// taken back when acpmux refuses it.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow, ConversationLayout } from "../src/agent-session/acpmux/model";
// These tests drive the compact (Codex) rail; the default arm draws no minimap (layout.experiment.ts).
(globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments = { "thread-minimap-layout": "compact" };

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  localStorage: dom.window.localStorage,
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const { act, createElement, createRef } = await import("react");
const { createRoot } = await import("react-dom/client");
const { ThreadMinimap } = await import("../src/agent-session/acpmux/threadMinimap/ThreadMinimap");
const { setBookmarkTransport } = await import("../src/agent-session/acpmux/threadMinimap/bookmarks");

afterAll(() => {
  setBookmarkTransport(undefined);
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const row = (id: string, kind: string, text: string): AcpmuxRow => ({ id, kind, text, version: 1, at: 1 });
// Four prompts (acpmux seqs 3, 7, 11 and 15; the rail shows from four), each with a reply.
const rows = [3, 7, 11, 15].flatMap((seq, index) => [
  row(`user-${seq}`, "user", `prompt ${index + 1}`),
  row(`assistant-${seq + 1}`, "assistant", `reply ${index + 1}`),
]);
const layout: ConversationLayout = {
  tops: Float64Array.from(rows.map((_, index) => index * 100)),
  heights: Float64Array.from(rows.map(() => 100)),
  totalHeight: rows.length * 100,
};

type Call = { sessionId: string; seq: number; bookmarked: boolean };
/// acpmux as the pane reaches it: a chat's marks, and a set that answers with the new list.
function daemon(initial: number[], refuse = false) {
  const marks = new Set(initial);
  const calls: Call[] = [];
  const gets: string[] = [];
  let release: () => void = () => {};
  const transport = {
    get: async (sessionId: string) => {
      gets.push(sessionId);
      return { sessionId, bookmarks: [...marks].sort((a, b) => a - b) };
    },
    set: (sessionId: string, seq: number, bookmarked: boolean) => {
      calls.push({ sessionId, seq, bookmarked });
      return new Promise<unknown>((resolve, reject) => {
        release = () => {
          if (refuse) return reject(new Error("refused"));
          if (bookmarked) marks.add(seq);
          else marks.delete(seq);
          resolve({ sessionId, bookmarks: [...marks].sort((a, b) => a - b) });
        };
      });
    },
  };
  return { transport, calls, gets, answer: () => release() };
}

const settle = () => act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));

async function mount() {
  const host = dom.window.document.createElement("div");
  dom.window.document.body.append(host);
  const root = createRoot(host);
  const scroller = createRef<HTMLElement>();
  await act(async () =>
    root.render(
      createElement(ThreadMinimap, {
        rows,
        sessionId: "chat-1",
        layout,
        scroller,
        scrollTop: 0,
        viewportHeight: 600,
        scrolls: true,
        width: 1040,
      }),
    ),
  );
  await settle();
  return { host, root };
}

/// Focuses tick `index` (its card opens at once) and returns the card's bookmark button.
async function bookmarkOf(host: HTMLElement, index: number): Promise<HTMLButtonElement> {
  await act(async () => host.querySelector<HTMLElement>(`[data-tick="${index}"]`)!.focus());
  return host.querySelector<HTMLButtonElement>(".acpmux-minimap__bookmark")!;
}

test("the popover bookmark sets the mark in acpmux and shows what acpmux answers", async () => {
  const acpmux = daemon([]);
  setBookmarkTransport(acpmux.transport);
  const { host, root } = await mount();
  expect(acpmux.gets).toEqual(["chat-1"]);
  const button = await bookmarkOf(host, 0);
  expect(button.getAttribute("aria-pressed")).toBe("false");
  expect(host.querySelector('[data-tick="0"] .acpmux-minimap__dot')).toBeNull();

  await act(async () => button.click());
  // Shown at once, before acpmux answers.
  expect(host.querySelector(".acpmux-minimap__bookmark")!.getAttribute("aria-pressed")).toBe("true");
  expect(acpmux.calls).toEqual([{ sessionId: "chat-1", seq: 3, bookmarked: true }]);
  await act(async () => acpmux.answer());
  await settle();
  expect(host.querySelector(".acpmux-minimap__bookmark")!.getAttribute("aria-pressed")).toBe("true");
  expect(host.querySelector('[data-tick="0"] .acpmux-minimap__dot')).not.toBeNull();

  await act(async () => (host.querySelector(".acpmux-minimap__bookmark") as HTMLButtonElement).click());
  expect(acpmux.calls.at(-1)).toEqual({ sessionId: "chat-1", seq: 3, bookmarked: false });
  await act(async () => acpmux.answer());
  await settle();
  expect(host.querySelector(".acpmux-minimap__bookmark")!.getAttribute("aria-pressed")).toBe("false");
  expect(host.querySelector('[data-tick="0"] .acpmux-minimap__dot')).toBeNull();
  await act(async () => root.unmount());
  host.remove();
});

test("a reloaded pane shows the marks acpmux keeps", async () => {
  // A fresh page: nothing local, the chat's marks come from bookmark_get.
  const acpmux = daemon([7]);
  setBookmarkTransport(acpmux.transport);
  const { host, root } = await mount();
  expect(acpmux.gets).toEqual(["chat-1"]);
  expect((await bookmarkOf(host, 1)).getAttribute("aria-pressed")).toBe("true");
  expect((await bookmarkOf(host, 0)).getAttribute("aria-pressed")).toBe("false");
  await act(async () => root.unmount());
  host.remove();
});

test("a refused toggle is taken back", async () => {
  const acpmux = daemon([], true);
  setBookmarkTransport(acpmux.transport);
  const { host, root } = await mount();
  const button = await bookmarkOf(host, 1);
  await act(async () => button.click());
  expect(host.querySelector(".acpmux-minimap__bookmark")!.getAttribute("aria-pressed")).toBe("true");
  expect(acpmux.calls).toEqual([{ sessionId: "chat-1", seq: 7, bookmarked: true }]);
  await act(async () => acpmux.answer());
  await settle();
  expect(host.querySelector(".acpmux-minimap__bookmark")!.getAttribute("aria-pressed")).toBe("false");
  await act(async () => root.unmount());
  host.remove();
});

test("an old local mark leaves localStorage only once acpmux keeps it", async () => {
  const KEY = "cmux.agentPane.threadBookmarks.v1";
  const keys = ["chat-1#user-3#a1", "chat-1#user-7#b2", "other#user-3#c3"];
  dom.window.localStorage.setItem(KEY, JSON.stringify(keys));
  // acpmux keeps the first and refuses the second (unreachable for a moment, say).
  const calls: Call[] = [];
  setBookmarkTransport({
    get: async (sessionId) => ({ sessionId, bookmarks: [] }),
    set: async (sessionId, seq, bookmarked) => {
      calls.push({ sessionId, seq, bookmarked });
      if (seq === 7) throw new Error("unreachable");
      return { sessionId, bookmarks: [seq] };
    },
  });
  const first = await mount();
  await settle();
  expect(calls).toEqual([
    { sessionId: "chat-1", seq: 3, bookmarked: true },
    { sessionId: "chat-1", seq: 7, bookmarked: true },
  ]);
  expect(JSON.parse(dom.window.localStorage.getItem(KEY) ?? "[]")).toEqual(["chat-1#user-7#b2", "other#user-3#c3"]);
  await act(async () => first.root.unmount());
  first.host.remove();

  // The next attach tries the one acpmux did not take again.
  const again: Call[] = [];
  setBookmarkTransport({
    get: async (sessionId) => ({ sessionId, bookmarks: [3] }),
    set: async (sessionId, seq, bookmarked) => {
      again.push({ sessionId, seq, bookmarked });
      return { sessionId, bookmarks: [3, seq] };
    },
  });
  const second = await mount();
  await settle();
  expect(again).toEqual([{ sessionId: "chat-1", seq: 7, bookmarked: true }]);
  expect(JSON.parse(dom.window.localStorage.getItem(KEY) ?? "[]")).toEqual(["other#user-3#c3"]);
  await act(async () => second.root.unmount());
  second.host.remove();
});

test("a reconnect keeps the marks on screen until the new connection reads them", async () => {
  // Leo, 2026-10-19: the bookmark dots left and came back on every reconnect.
  const acpmux = daemon([7]);
  setBookmarkTransport(acpmux.transport);
  const { host, root } = await mount();
  expect((await bookmarkOf(host, 1)).getAttribute("aria-pressed")).toBe("true");
  // acpmux restarts: a new connection whose read has not answered yet.
  await act(async () =>
    setBookmarkTransport({ get: () => new Promise<never>(() => {}), set: () => new Promise<never>(() => {}) }),
  );
  await settle();
  expect((await bookmarkOf(host, 1)).getAttribute("aria-pressed")).toBe("true");
  await act(async () => root.unmount());
  host.remove();
});
