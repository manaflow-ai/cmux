// The Feed's Needs you rows (pages/feed/NeedsYouView.tsx NeedsYouRow) draw again only when their own
// request changed: a later clock and a selection draw no row, and the ages move in their own leaves.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import { createRoot, rowRenders } from "./support/rowRenders";
import { settleReact } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const names = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "HTMLInputElement",
  "Element",
  "Node",
  "MouseEvent",
  "KeyboardEvent",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "ResizeObserver",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = names.map((name) => [name, scope[name]] as const);
let dom: JSDOM;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/feed/",
    pretendToBeVisual: true,
  });
  const win = dom.window as unknown as Record<string, unknown>;
  for (const name of names) scope[name] = name === "window" ? dom.window : win[name];
  scope.IS_REACT_ACT_ENVIRONMENT = true;
  scope.getComputedStyle = dom.window.getComputedStyle.bind(dom.window);
  scope.requestAnimationFrame = (callback: FrameRequestCallback) =>
    setTimeout(() => callback(Date.now()), 0) as unknown as number;
  scope.cancelAnimationFrame = (handle: number) => clearTimeout(handle);
  dom.window.HTMLElement.prototype.scrollIntoView = () => undefined;
});

afterAll(async () => {
  await settleReact();
  dom.window.close();
  for (const [name, value] of saved) {
    if (value === undefined) delete scope[name];
    else scope[name] = value;
  }
});

const { FeedPage } = await import("../src/pages/feed/FeedPage");
const { UiProvider } = await import("../src/ui/UiProvider");
const { createStrings } = await import("../src/pages/shared/i18n");
const table = (await import("../src/pages/feed/generated/strings.json")).default as Record<
  string,
  Record<string, string>
>;
const { MockFeedProvider, sampleFeed } = await import("../src/pages/feed/mockProvider");
const { FeedStore } = await import("../src/pages/feed/store");

test("Needs you rows: a later clock and a selection draw no row; the ages move in their own leaves", async () => {
  const start = Date.now();
  let now = start;
  const provider = new MockFeedProvider(sampleFeed(start), {});
  const strings = createStrings(table, ["en"]);
  const store = new FeedStore(provider, "#/needs-you?style=rows&limit=50", { clock: () => now });
  const host = dom.window.document.getElementById("root")!;
  const root = createRoot(host);
  await act(async () => {
    root.render(
      <UiProvider container={host}>
        <FeedPage store={store} strings={strings} />
      </UiProvider>,
    );
  });
  await act(async () => {
    await store.start();
  });
  const rows = () => [...host.querySelectorAll<HTMLElement>(".feed-needs-row")];
  const ages = () => rows().map((row) => row.querySelector(".feed-needs-meta")?.textContent);
  expect(rows().length).toBeGreaterThan(1);
  const before = ages();
  // A minute later, a new snapshot (a selection publishes the store's clock): no request changed.
  now += 3_600_000;
  rowRenders.reset();
  // A selection is not an answer: pick a notice that is not one of the rows.
  const shown = new Set(rows().map((row) => row.getAttribute("data-item")));
  const other = sampleFeed(start).find((item) => item.kind === "notice" && !shown.has(item.id))!;
  await act(async () => store.select(other.id));
  expect(rowRenders.count("NeedsYouRow")).toBe(0);
  // The ages redraw through context alone, which rowRenders does not count (a context-only render
  // makes no new props or hook state), so they are checked by their text.
  expect(ages()).not.toEqual(before);
  // A selection with the same clock: no row and no age.
  rowRenders.reset();
  await act(async () => store.select("none"));
  expect(rowRenders.count("NeedsYouRow")).toBe(0);
  act(() => root.unmount());
});
