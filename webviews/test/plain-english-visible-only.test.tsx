// Plain English draws what is visible (the visible-only rule): at 1,000 and 10,000 hunks the view
// mounts the same rows and DOM nodes, a sentence arriving and a one-row scroll draw again only the
// rows they changed, a scroll reads no row's layout, and only mounted rows ask for a sentence.
// Before, every hunk of every file was a mounted row (content-visibility skipped only their paint).
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { parsePatchFiles } from "@pierre/diffs";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { PlainEnglishFile } from "../src/diff-viewer/PlainEnglishView";
import type { HunkRef, SummaryFileDiff } from "../src/diff-viewer/hunkSummaries";
import { rowRenders } from "./support/commitRenders";
import { settleReact } from "./support/domTeardown";
import { mountedRowRenders } from "./support/mountedRowRenders";
import { installVirtualSizes } from "./support/virtualSizes";

const scope = globalThis as Record<string, unknown>;
const names = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Element",
  "Node",
  "SVGElement",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IntersectionObserver",
  "ResizeObserver",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = names.map((name) => [name, scope[name]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

/** The view's IntersectionObserver, where every observed row is near: what is mounted is what asks. */
class AllNear {
  constructor(private readonly callback: (entries: { target: Element; isIntersecting: boolean }[]) => void) {}
  observe(target: Element) {
    queueMicrotask(() => this.callback([{ target, isIntersecting: true }]));
  }
  unobserve() {}
  disconnect() {}
}

/** A 600 px view of 54 px rows and 24 px paths (styles.css). */
const plainEnglishSizes = (element: HTMLElement) =>
  element.classList.contains("plain-english") ? 600 : element.tagName === "H3" ? 24 : 54;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/diff/",
    pretendToBeVisual: true,
  });
  const win = dom.window as unknown as Record<string, unknown>;
  for (const name of names) scope[name] = name === "window" ? dom.window : win[name];
  scope.IS_REACT_ACT_ENVIRONMENT = true;
  scope.getComputedStyle = dom.window.getComputedStyle.bind(dom.window);
  scope.requestAnimationFrame = (callback: FrameRequestCallback) =>
    setTimeout(() => callback(Date.now()), 0) as unknown as number;
  scope.cancelAnimationFrame = (handle: number) => clearTimeout(handle);
  scope.IntersectionObserver = AllNear;
  // An unfolded row's Pierre code watches its size; jsdom has no layout to watch.
  scope.ResizeObserver = class {
    observe() {}
    unobserve() {}
    disconnect() {}
  };
  installVirtualSizes(dom.window, plainEnglishSizes);
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
});

afterAll(async () => {
  await settleReact();
  dom.window.close();
  for (const [name, value] of saved) {
    if (value === undefined) delete scope[name];
    else scope[name] = value;
  }
});

const { createRoot } = await import("react-dom/client");
const { PlainEnglishView } = await import("../src/diff-viewer/PlainEnglishView");
const { SummaryStore } = await import("../src/diff-viewer/hunkSummaries");

/** `count` files of `hunks` hunks each. */
function files(count: number, hunks: number): PlainEnglishFile[] {
  return Array.from({ length: count }, (_, f) => {
    let patch = `diff --git a/src/f${f}.ts b/src/f${f}.ts\n--- a/src/f${f}.ts\n+++ b/src/f${f}.ts\n`;
    for (let h = 0; h < hunks; h++) {
      const line = 1 + h * 20;
      patch += `@@ -${line},2 +${line},2 @@\n context ${h}\n-old ${f}.${h}\n+new ${f}.${h}\n`;
    }
    return { itemId: `item-${f}`, fileDiff: parsePatchFiles(patch)[0]!.files[0] as unknown as SummaryFileDiff };
  });
}

const label = ((key: string) => key) as never;
const settle = () => act(async () => new Promise((resolve) => setTimeout(resolve, 0)));

async function mount(fileCount: number) {
  const asks: { ref: string; answer: (text: string) => void }[] = [];
  const store = new SummaryStore(
    (path, patch) => new Promise((resolve) => asks.push({ ref: `${path}|${patch}`, answer: resolve })),
  );
  const wanted: number[] = [];
  const want = store.want.bind(store);
  store.want = (refs: readonly HunkRef[]) => {
    wanted.push(refs.length);
    want(refs);
  };
  host = dom.window.document.getElementById("root")!;
  root = createRoot(host);
  await act(async () => root!.render(<PlainEnglishView files={files(fileCount, 10)} store={store} label={label} />));
  await settle();
  await settle();
  return { asks, wanted, view: host.querySelector<HTMLElement>(".plain-english")! };
}

const rows = () => host.querySelectorAll(".plain-english-hunk").length;
const renders = mountedRowRenders(() => host.querySelectorAll(".plain-english-hunk"), "HunkSentence");

/** Mounted rows and nodes, and the row renders of one sentence arriving and one one-row scroll. */
async function measure(fileCount: number) {
  const { asks, wanted, view } = await mount(fileCount);
  const mounted = { rows: rows(), nodes: view.querySelectorAll("*").length };

  // Counted from React's commits (support/commitRenders.ts): a row's HunkSentence redraws from its
  // store subscription with the props it had, which a props count does not see.
  const commits = rowRenders();
  commits.begin(host, ".plain-english-hunk");
  await act(async () => asks[0]!.answer("Renames old to new."));
  await settle();
  const sentence = commits.end();
  expect(host.querySelectorAll('.plain-english-row[data-state="ready"]').length).toBe(1);

  const rects = { calls: 0 };
  const original = dom.window.Element.prototype.getBoundingClientRect;
  dom.window.Element.prototype.getBoundingClientRect = function (this: Element) {
    rects.calls++;
    return original.call(this);
  };
  // Far into the diff, then one row on.
  await act(async () => view.scrollTo({ top: 54 * 400 }));
  await settle();
  renders.mark();
  rects.calls = 0;
  await act(async () => {
    view.scrollTop += 54;
    view.dispatchEvent(new dom.window.Event("scroll"));
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  await settle();
  const scroll = { renders: renders.since(), rects: rects.calls, rows: rows() };
  dom.window.Element.prototype.getBoundingClientRect = original;
  return { mounted, sentence, scroll, mostWanted: Math.max(...wanted), n: fileCount * 10 };
}

test("1,000 and 10,000 hunks mount the same rows, and one event draws only the rows it changed", async () => {
  const small = await measure(100);
  act(() => root?.unmount());
  const large = await measure(1_000);
  console.log(JSON.stringify({ small, large }));

  // Rule 1: the viewport's rows (600 / 54) and about one viewport each side, not the diff.
  for (const run of [small, large]) {
    expect(run.mounted.rows).toBeGreaterThan(8);
    expect(run.mounted.rows).toBeLessThanOrEqual(50);
    expect(run.scroll.rows).toBeLessThanOrEqual(50);
    // Only mounted rows ask for a sentence.
    expect(run.mostWanted).toBeLessThanOrEqual(50);
  }
  expect(Math.abs(large.mounted.rows - small.mounted.rows)).toBeLessThanOrEqual(small.mounted.rows * 0.1);
  expect(Math.abs(large.mounted.nodes - small.mounted.nodes)).toBeLessThanOrEqual(small.mounted.nodes * 0.1);
  expect(Math.abs(large.scroll.rows - small.scroll.rows)).toBeLessThanOrEqual(small.scroll.rows * 0.1);

  for (const run of [small, large]) {
    // Rule 2: a sentence arriving draws its own row once, and no other mounted row.
    expect(run.sentence).toEqual({ rerendered: 1, wasted: 0, added: 0, maxRenders: 1 });
    // One row's scroll draws only the rows it brings in; the mounted ones keep their place.
    expect(run.scroll.renders).toBeLessThanOrEqual(2);
  }
  // Rule 3: a scroll reads no row's layout, at any length.
  expect(large.scroll.rects).toBe(small.scroll.rects);
});

test("an unfolded row and a focused row keep their state far past the window", async () => {
  const { view } = await mount(100);
  const first = host.querySelector<HTMLButtonElement>('[data-hunk-id="item-0#0"] .plain-english-row')!;
  await act(async () => first.click());
  await act(async () => first.focus());
  expect(first.getAttribute("aria-expanded")).toBe("true");
  await act(async () => view.scrollTo({ top: 54 * 500 }));
  await settle();
  // Focus stays on its row, which stays mounted, while the window is 500 rows on.
  expect(first.isConnected).toBe(true);
  expect(dom.window.document.activeElement).toBe(first);
  expect(rows()).toBeLessThanOrEqual(51);
  await act(async () => first.blur());
  await settle();
  expect(first.isConnected).toBe(false);
  // Back at the top, the row is still unfolded.
  await act(async () => view.scrollTo({ top: 0 }));
  await settle();
  const again = host.querySelector<HTMLButtonElement>('[data-hunk-id="item-0#0"] .plain-english-row')!;
  expect(again.getAttribute("aria-expanded")).toBe("true");
  expect(again.closest("li")!.getAttribute("aria-posinset")).toBe("1");
  expect(again.closest("li")!.getAttribute("aria-setsize")).toBe("10");
});
