// l10n-allow-file: development workbench labels and fixture titles, not shipped UI.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { Overview, OVERVIEW_PREVIEW_LIMIT, scenarioHref } from "../src/gallery/parity/Overview";
import { SCENARIOS, scenarioFrame } from "../src/gallery/parity/scenarios";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Element",
  "location",
  "history",
  "ResizeObserver",
  "IntersectionObserver",
  "IS_REACT_ACT_ENVIRONMENT",
];
const saved = keys.map((key) => [key, Object.getOwnPropertyDescriptor(scope, key)] as const);
let dom: JSDOM;
let root: Root;
let host: HTMLElement;

class Intersections {
  static instances: Intersections[] = [];
  nodes: Element[] = [];
  disconnected = false;
  constructor(readonly callback: IntersectionObserverCallback) {
    Intersections.instances.push(this);
  }
  observe(node: Element) {
    this.nodes.push(node);
  }
  disconnect() {
    this.disconnected = true;
  }
  emit(nodes: Element[], isIntersecting: boolean) {
    this.callback(
      nodes.map((target, index) => ({
        target,
        isIntersecting,
        boundingClientRect: { top: index * 100, height: 400 },
      })) as IntersectionObserverEntry[],
      this as unknown as IntersectionObserver,
    );
  }
}
class Sizes {
  disconnected = false;
  constructor(readonly callback: ResizeObserverCallback) {}
  observe(target: Element) {
    this.callback(
      [
        { target, contentRect: { width: 380, height: 64 }, borderBoxSize: [{ blockSize: 64 }] },
      ] as unknown as ResizeObserverEntry[],
      this as unknown as ResizeObserver,
    );
  }
  disconnect() {
    this.disconnected = true;
  }
}

beforeEach(() => {
  dom = new JSDOM("<!doctype html><main id=test-root></main>", {
    url: "http://localhost/gallery/chat-parity.html?scenario=command-done",
  });
  dom.window.scrollTo = () => {};
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    location: dom.window.location,
    history: dom.window.history,
    ResizeObserver: Sizes,
    IntersectionObserver: Intersections,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  Intersections.instances = [];
  host = document.getElementById("test-root")!;
  root = createRoot(host);
});
afterEach(async () => {
  await act(async () => root.unmount());
  dom.window.close();
  for (const [key, descriptor] of saved) {
    if (descriptor) Object.defineProperty(scope, key, descriptor);
    else delete scope[key];
  }
});

test("overview lists every real scenario while mounting at most four nearby previews and releases distant frames", async () => {
  await act(async () => root.render(<Overview onSelect={() => {}} />));
  expect(host.querySelectorAll("article")).toHaveLength(SCENARIOS.length);
  expect(host.querySelectorAll("iframe")).toHaveLength(0);
  const observer = Intersections.instances[0]!;
  expect(observer.nodes).toHaveLength(SCENARIOS.length);
  await act(async () => observer.emit(observer.nodes.slice(0, 10), true));
  expect(host.querySelectorAll("iframe")).toHaveLength(OVERVIEW_PREVIEW_LIMIT);
  for (const frame of host.querySelectorAll("iframe")) {
    expect(frame.width).toBe("760");
    expect(frame.style.transform).toBe("scale(0.5)");
    expect(frame.tabIndex).toBe(-1);
    const id = frame.closest<HTMLElement>("[data-parity-preview]")!.dataset.parityPreview;
    const scenario = SCENARIOS.find((item) => item.id === id)!;
    expect(frame.getAttribute("src")).toBe(scenarioFrame(scenario, "dark", 760));
  }
  await act(async () => observer.emit(observer.nodes.slice(0, 10), false));
  expect(host.querySelectorAll("iframe")).toHaveLength(0);
  await act(async () => observer.emit(observer.nodes.slice(-2), true));
  expect(host.querySelectorAll("iframe")).toHaveLength(2);
  await act(async () => root.unmount());
  expect(observer.disconnected).toBe(true);
  root = createRoot(host);
});

test("overview links open the requested interactive scenario in the fixed dark viewport", async () => {
  let selected: string | undefined;
  await act(async () =>
    root.render(
      <Overview
        onSelect={(id) => {
          selected = id;
        }}
      />,
    ),
  );
  const links = [...host.querySelectorAll<HTMLAnchorElement>(".parity-overview__card-heading a")];
  expect(links).toHaveLength(SCENARIOS.length);
  for (let index = 0; index < links.length; index += 1) {
    const url = new URL(links[index]!.href);
    const id = links[index]!.closest("article")!
      .querySelector<HTMLElement>("[data-parity-preview]")!
      .getAttribute("data-parity-preview");
    expect(SCENARIOS.some((scenario) => scenario.id === id)).toBe(true);
    expect(url.searchParams.get("scenario")).toBe(id);
    expect(url.searchParams.get("view")).toBeNull();
    expect(url.searchParams.get("appearance")).toBe("dark");
    expect(url.searchParams.get("width")).toBe("760");
  }
  await act(async () =>
    links[0]!.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true, cancelable: true })),
  );
  expect(selected).toBe(SCENARIOS[0]!.id);
  const link = scenarioHref(
    "chief-task",
    "http://localhost/gallery/chat-parity.html?view=overview&scenario=completed#scenario-group-2",
  );
  expect(new URL(link).hash).toBe("");
});

test("nearby previews are ranked by their current positions after scrolling", async () => {
  await act(async () => root.render(<Overview onSelect={() => {}} />));
  const observer = Intersections.instances[0]!;
  const nodes = observer.nodes.slice(0, 8);
  const tops: number[] = nodes.map((_, index) => (index < 4 ? 100 : 500));
  for (const [index, node] of nodes.entries())
    node.getBoundingClientRect = () => ({ top: tops[index]!, height: 200 }) as DOMRect;
  const shown = () =>
    [...host.querySelectorAll("iframe")].map(
      (frame) => frame.closest<HTMLElement>("[data-parity-preview]")!.dataset.parityPreview,
    );
  await act(async () => observer.emit(nodes, true));
  expect(shown()).toEqual(SCENARIOS.slice(0, 4).map((scenario) => scenario.id));
  for (let index = 0; index < nodes.length; index += 1) tops[index] = index < 4 ? -150 : 200;
  // Only one target crosses an observer boundary. Every nearby target's fresh position still counts.
  await act(async () => observer.emit(nodes.slice(0, 1), true));
  expect(shown()).toEqual(SCENARIOS.slice(4, 8).map((scenario) => scenario.id));
});

test("focus mode preserves URL selection on rerender, navigates adjacent scenarios, and returns from overview", async () => {
  const { Workbench } = await import("../src/gallery/parity/main");
  await act(async () => root.render(<Workbench />));
  const index = SCENARIOS.findIndex((item) => item.id === "command-done");
  const frame = () => host.querySelector<HTMLIFrameElement>(".parity-stage iframe")!;
  expect(frame().getAttribute("src")).toBe(scenarioFrame(SCENARIOS[index]!, "dark", 760));
  const button = (label: string) =>
    [...host.querySelectorAll<HTMLButtonElement>("button")].find((node) => node.textContent === label)!;
  await act(async () => button("Next").click());
  expect(location.search).toContain(`scenario=${SCENARIOS[index + 1]!.id}`);
  await act(async () => root.render(<Workbench />));
  expect(frame().getAttribute("src")).toBe(scenarioFrame(SCENARIOS[index + 1]!, "dark", 760));
  await act(async () => button(`All scenarios · ${SCENARIOS.length}`).click());
  expect(new URL(location.href).searchParams.get("view")).toBe("overview");
  expect(host.querySelectorAll("article")).toHaveLength(SCENARIOS.length);
  Object.defineProperty(window, "scrollY", { configurable: true, writable: true, value: 9_000 });
  const scrolls: number[] = [];
  window.scrollTo = ((options: ScrollToOptions) => {
    scrolls.push(options.top ?? 0);
    Object.defineProperty(window, "scrollY", { configurable: true, writable: true, value: options.top ?? 0 });
  }) as typeof window.scrollTo;
  const last = [...host.querySelectorAll<HTMLAnchorElement>(".parity-overview__card-heading a")].at(-1)!;
  await act(async () => last.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true, cancelable: true })));
  expect(new URL(location.href).searchParams.get("scenario")).toBe(SCENARIOS.at(-1)!.id);
  expect(new URL(location.href).searchParams.get("view")).toBeNull();
  expect(host.querySelectorAll("article")).toHaveLength(0);
  expect(scrolls.at(-1)).toBe(0);
  await act(async () => button(`All scenarios · ${SCENARIOS.length}`).click());
  expect(scrolls.at(-1)).toBe(9_000);
  await act(async () => button("One scenario").click());
  await act(async () => button("Next").click());
  expect(new URL(location.href).searchParams.get("scenario")).toBe(SCENARIOS[0]!.id);
});

test("an explicit overview URL starts with all scenarios and no eager fixture mounts", async () => {
  history.replaceState(null, "", "?view=overview&scenario=chief-task");
  const { Workbench } = await import("../src/gallery/parity/main");
  await act(async () => root.render(<Workbench />));
  expect(host.querySelectorAll("article")).toHaveLength(SCENARIOS.length);
  expect(host.querySelectorAll("iframe")).toHaveLength(0);
  expect(new URL(location.href).searchParams.get("scenario")).toBe("chief-task");
});
