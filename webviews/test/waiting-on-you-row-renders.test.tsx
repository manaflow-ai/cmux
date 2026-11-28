// l10n-allow-file: test fixtures (sample asks), not shipped UI.
// Waiting on you's rows (queue/QueueScreen.tsx) render only when their own item changed: the pane
// handing in new action functions (each of its renders) draws no row, a new read that changes one
// item draws that row alone (its new time redraws only the age labels), and moving the cursor draws
// the two rows it moved between. Counted from React's commits (support/rowRenders.ts).
import { createRoot, rowRenders } from "./support/rowRenders";
import { afterAll, afterEach, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
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
  MutationObserver: dom.window.MutationObserver,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent|CustomEvent)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
// jsdom has no layout: scrolling a row into view is a no-op here.
dom.window.HTMLElement.prototype.scrollIntoView = () => {};
const host = dom.window.document.getElementById("root")!;
let root: Root | undefined;

const { QueueScreen } = await import("../src/agent-session/acpmux/queue/QueueScreen");
const { createQueueCache } = await import("../src/agent-session/acpmux/queue/useQueue");

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
});
afterAll(async () => {
  await teardownDom(saved, { scope });
});

const MINUTE = 60_000;
// A fresh object per item each read, as acpmux's JSON is.
// `score` moves on every read, as acpmux works it out from the item's age at read time.
const items = (n: number, ask = (index: number) => `Run step ${index}`, read = 0) =>
  Array.from({ length: n }, (_, index) => ({
    id: `acpmux:p${index}`,
    kind: "approval",
    sessionId: `s${index}`,
    title: `Chat ${index}`,
    ask: ask(index),
    at: index * MINUTE,
    score: n - index + read / 1000,
    permissionId: `p${index}`,
    options: [
      { optionId: "allow", name: "Allow", kind: "allow_once" },
      { optionId: "deny", name: "Deny", kind: "reject_once" },
    ],
  }));

async function mount(n: number) {
  let reply: unknown = { items: items(n), now: n * MINUTE, total: n };
  const cache = createQueueCache();
  // New functions on every render, as the pane's historyPages() makes them.
  const element = () => (
    <QueueScreen
      load={async () => reply}
      answer={async () => "answered" as const}
      verdict={async () => undefined}
      open={() => {}}
      exportAudit={async () => 0}
      cache={cache}
    />
  );
  rowRenders.clear();
  root = createRoot(host);
  await act(async () => root!.render(element()));
  await act(async () => {
    await Promise.resolve();
  });
  return {
    rerender: () => act(() => root!.render(element())),
    read: async (next: unknown) => {
      reply = next;
      await act(async () => cache.refresh());
      await act(async () => {
        await Promise.resolve();
      });
    },
    key: (key: string) =>
      act(
        () =>
          void host
            .querySelector(".wq-list")!
            .dispatchEvent(new dom.window.KeyboardEvent("keydown", { key, bubbles: true })),
      ),
  };
}

for (const n of [100, 1_000]) {
  test(`the pane's render with new action functions draws none of ${n} rows`, async () => {
    const page = await mount(n);
    expect(host.querySelectorAll(".wq-row").length).toBe(n);
    rowRenders.reset();
    page.rerender();
    expect(rowRenders.count("Row")).toBe(0);
  });

  test(`a read that changes one of ${n} items draws that row alone`, async () => {
    const page = await mount(n);
    rowRenders.reset();
    await page.read({
      items: items(n, (index) => (index === 4 ? "Run the release" : `Run step ${index}`), 1),
      now: n * MINUTE + MINUTE,
      total: n,
    });
    expect(host.textContent).toContain("Run the release");
    expect(rowRenders.count("Row")).toBe(1);
  });

  test(`a read whose only change is every score (time passed) draws none of ${n} rows`, async () => {
    const page = await mount(n);
    rowRenders.reset();
    await page.read({ items: items(n, undefined, 2), now: n * MINUTE + 2 * MINUTE, total: n });
    expect(rowRenders.count("Row")).toBe(0);
  });

  test(`moving the cursor among ${n} rows draws the two it moved between`, async () => {
    const page = await mount(n);
    page.key("j");
    rowRenders.reset();
    page.key("j");
    expect(rowRenders.count("Row")).toBe(2);
  });
}
