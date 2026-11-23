// A chat's first bookmark read that finds no marks renders nothing again: the rail and its pins keep
// the shared empty set. A chat switch reads the new chat's marks while its first frame is pending,
// and an empty answer re-rendered the rail and every pin before that frame painted
// (bench/settled-page.bench.ts, chat_switch). A read that finds marks still shows them.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { teardownDom } from "./support/domTeardown";

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
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { setBookmarkTransport, useBookmarks } = await import("../src/agent-session/acpmux/threadMinimap/bookmarks");

afterAll(async () => {
  setBookmarkTransport(undefined);
  await teardownDom(saved, { window: dom.window, scope });
});

async function shown(sessionId: string, bookmarks: number[]) {
  setBookmarkTransport({
    get: async (asked) => ({ sessionId: asked, bookmarks }),
    set: async () => ({ sessionId, bookmarks }),
  });
  const seen: ReadonlySet<number>[] = [];
  function Probe() {
    seen.push(useBookmarks(sessionId).marks);
    return null;
  }
  const host = dom.window.document.createElement("div");
  dom.window.document.body.append(host);
  const root = createRoot(host);
  await act(async () => root.render(createElement(Probe)));
  await act(async () => {
    await new Promise((done) => setTimeout(done, 0));
  });
  await act(async () => root.unmount());
  host.remove();
  return seen;
}

test("an empty read keeps the empty marks shown: no render after the read", async () => {
  const seen = await shown("chat-empty", []);
  expect(seen.length).toBe(1);
  expect([...(seen[0] ?? [])]).toEqual([]);
});

test("a read that finds marks shows them", async () => {
  const seen = await shown("chat-marked", [3, 7]);
  expect(seen.length).toBe(2);
  expect([...(seen[1] ?? [])].sort((a, b) => a - b)).toEqual([3, 7]);
});
