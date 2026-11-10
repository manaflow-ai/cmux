// The see-through Chief on the Messages page (seeThrough.ts; ChiefPanelStyle.seeThrough and .seeThroughBar,
// ported from the native transcript's clearsBackground and HomeHostView.chiefHeaderHeight): the host's switch
// turns the page's own background off and back on, and while it is on the page reports its header's height.
import { afterEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

/** The page's ResizeObservers, so a test can say the header changed size. */
const observers: { callback: () => void; targets: Element[] }[] = [];

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { pretendToBeVisual: true });
  class FakeResizeObserver {
    entry: { callback: () => void; targets: Element[] };
    constructor(callback: () => void) {
      this.entry = { callback, targets: [] };
      observers.push(this.entry);
    }
    observe(target: Element) {
      this.entry.targets.push(target);
    }
    unobserve() {}
    disconnect() {
      this.entry.targets = [];
    }
  }
  for (const key of [
    "window",
    "document",
    "navigator",
    "HTMLElement",
    "Element",
    "Node",
    "ResizeObserver",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    ResizeObserver: FakeResizeObserver,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(() => {
  if (root) act(() => root!.unmount());
  root = undefined;
  observers.length = 0;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const { SEE_THROUGH_ATTRIBUTE, SeeThroughOps, parseSeeThrough, useSeeThrough } =
  await import("../src/pages/home-messages/seeThrough");
const { TranscriptHeader } = await import("../src/pages/home-messages/transcript/TranscriptHeader");
const { createTranscriptStrings } = await import("../src/pages/home-messages/transcript/strings");
type PageClient = import("../src/pages/shared/pageClient").PageClient;

const strings = createTranscriptStrings(["en"]);
const settle = () => act(async () => new Promise((resolve) => setTimeout(resolve, 0)));

/** A host with the `seeThrough` stream: `emit` sends its switch; `calls` are the page's reports. */
function fakeHost() {
  const listeners = new Set<(event: unknown) => void>();
  const calls: { op: string; params: unknown }[] = [];
  const host = {
    call: async (op: string, params: unknown) => {
      calls.push({ op, params });
      return null;
    },
    subscribe: async (stream: string, onEvent: (event: unknown) => void) => {
      if (stream !== SeeThroughOps.stream) return () => {};
      listeners.add(onEvent);
      onEvent({ showsThrough: false });
      return () => listeners.delete(onEvent);
    },
    handle: () => () => {},
  } as unknown as PageClient;
  const emit = (event: unknown) => act(() => listeners.forEach((listener) => listener(event)));
  return { host, calls, emit };
}

/** A page with the hook and one transcript header whose bottom is `bottom()` CSS px. */
function Page({ host, header }: { host: PageClient; header: boolean }) {
  useSeeThrough(host);
  return header ? <TranscriptHeader title="Chief" strings={strings} /> : null;
}

/** The browser's resize pass: every observer still observing hears it (a disconnected one does not). */
const resize = () =>
  act(() => observers.filter((entry) => entry.targets.length > 0).forEach((entry) => entry.callback()));

function stubHeaderBottom(bottom: () => number) {
  const header = document.querySelector<HTMLElement>(".mt-header")!;
  header.getBoundingClientRect = () => ({ bottom: bottom() }) as DOMRect;
  return header;
}

const headerReports = (calls: { op: string; params: unknown }[]) =>
  calls.filter((call) => call.op === SeeThroughOps.header).map((call) => (call.params as { height: number }).height);

test("the switch reads only {showsThrough: true} as on", () => {
  expect(parseSeeThrough({ showsThrough: true })).toBe(true);
  expect(parseSeeThrough({ showsThrough: false })).toBe(false);
  expect(parseSeeThrough({ showsThrough: "yes" })).toBe(false);
  expect(parseSeeThrough(null)).toBe(false);
  expect(parseSeeThrough([true])).toBe(false);
});

test("the host's switch clears the page's background and puts it back", async () => {
  const container = installDom();
  const { host, emit } = fakeHost();
  root = createRoot(container);
  await act(async () => root!.render(<Page host={host} header={false} />));
  await settle();
  const html = document.documentElement;
  expect(html.hasAttribute(SEE_THROUGH_ATTRIBUTE)).toBe(false);
  emit({ showsThrough: true });
  expect(html.hasAttribute(SEE_THROUGH_ATTRIBUTE)).toBe(true);
  emit({ showsThrough: false });
  expect(html.hasAttribute(SEE_THROUGH_ATTRIBUTE)).toBe(false);
  // The page leaving the see-through panel takes the style with it.
  emit({ showsThrough: true });
  act(() => root!.unmount());
  root = undefined;
  expect(html.hasAttribute(SEE_THROUGH_ATTRIBUTE)).toBe(false);
});

test("the style drops the page fill and the header's own plate, and puts no halo on the chat", () => {
  const css = readFileSync(new URL("../src/pages/home-messages/styles.css", import.meta.url), "utf8");
  const rule = (selector: string) => {
    const start = css.indexOf(`${selector} {`);
    expect(start).toBeGreaterThanOrEqual(0);
    return css.slice(start, css.indexOf("}", start));
  };
  expect(rule(`:root[${SEE_THROUGH_ATTRIBUTE}]`)).toContain("background: transparent");
  const header = rule(`:root[${SEE_THROUGH_ATTRIBUTE}] .mt-header`);
  expect(header).toContain("background: transparent");
  expect(header).toContain("backdrop-filter: none");
  expect(css).not.toMatch(/data-home-see-through[^{]*\{[^}]*(text-shadow|filter: drop-shadow)/);
});

test("while see-through the page reports its header's height, once per change, and stops after", async () => {
  const container = installDom();
  const { host, calls, emit } = fakeHost();
  root = createRoot(container);
  await act(async () => root!.render(<Page host={host} header />));
  await settle();
  let bottom = 72.4;
  stubHeaderBottom(() => bottom);
  // Off: nothing reported.
  expect(headerReports(calls)).toEqual([]);
  emit({ showsThrough: true });
  expect(headerReports(calls)).toEqual([73]);
  // A resize that keeps the height reports nothing; one that changes it reports the new height.
  resize();
  bottom = 96;
  resize();
  expect(headerReports(calls)).toEqual([73, 96]);
  // Off again: no more reports.
  emit({ showsThrough: false });
  bottom = 120;
  resize();
  expect(headerReports(calls)).toEqual([73, 96]);
});

test("a header that goes away reports 0, and the next one its own height", async () => {
  const container = installDom();
  const { host, calls, emit } = fakeHost();
  root = createRoot(container);
  await act(async () => root!.render(<Page host={host} header />));
  await settle();
  stubHeaderBottom(() => 60);
  emit({ showsThrough: true });
  expect(headerReports(calls)).toEqual([60]);
  await act(async () => root!.render(<Page host={host} header={false} />));
  expect(headerReports(calls)).toEqual([60, 0]);
  await act(async () => root!.render(<Page host={host} header />));
  // jsdom lays nothing out: an unstubbed header's bottom is 0, so stub it and say it resized.
  stubHeaderBottom(() => 88);
  resize();
  expect(headerReports(calls)).toEqual([60, 0, 88]);
});
