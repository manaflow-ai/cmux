// A New Tab list keeps its layout snapshot when its owner rerenders for unrelated state. The motion
// hook should only reread row geometry when the list, selector, or row-key signature changes.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { type CSSProperties, StrictMode, useRef, useState } from "react";

const scope = globalThis as Record<string, unknown>;
const globals = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Element",
  "Node",
  "DOMRect",
  "IS_REACT_ACT_ENVIRONMENT",
  "getComputedStyle",
  "matchMedia",
  "ResizeObserver",
] as const;
const saved = globals.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;
const observers: { target: Element | null; disconnects: number; resize(): void }[] = [];

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
  Object.assign(window, {
    matchMedia: () => ({ matches: false }),
    ResizeObserver: class {
      state = { target: null as Element | null, disconnects: 0, resize: () => {} };
      constructor(callback: ResizeObserverCallback) {
        this.state.resize = () => callback([], this as unknown as ResizeObserver);
        observers.push(this.state);
      }
      observe(target: Element) {
        this.state.target = target;
      }
      disconnect() {
        this.state.target = null;
        this.state.disconnects += 1;
      }
    },
  });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    Element: window.Element,
    Node: window.Node,
    DOMRect: window.DOMRect,
    IS_REACT_ACT_ENVIRONMENT: true,
    getComputedStyle: window.getComputedStyle.bind(window),
    matchMedia: window.matchMedia.bind(window),
    ResizeObserver: window.ResizeObserver,
  });
  host = window.document.getElementById("root")!;
});

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

test("does not remeasure when the owner rerenders with the same list signature", async () => {
  const { useListMotion } = await import("../src/agent-session/acpmux/newtab/listMotion");
  let rerender!: () => void;
  function Harness() {
    const [, setTick] = useState(0);
    const list = useRef<HTMLDivElement>(null);
    rerender = () => setTick((tick) => tick + 1);
    useListMotion(list, ".row", ["a"]);
    return (
      <div ref={list}>
        <div className="row" />
      </div>
    );
  }

  const originalQuerySelectorAll = Element.prototype.querySelectorAll;
  const originalGetBoundingClientRect = HTMLElement.prototype.getBoundingClientRect;
  const originalGetComputedStyle = scope.getComputedStyle as typeof getComputedStyle;
  let queries = 0;
  let rects = 0;
  let computedStyles = 0;
  Element.prototype.querySelectorAll = function (...args) {
    queries += 1;
    return originalQuerySelectorAll.call(this, args[0]!);
  };
  HTMLElement.prototype.getBoundingClientRect = function () {
    rects += 1;
    return new DOMRect(0, 0, 100, 20);
  };
  scope.getComputedStyle = (() => {
    computedStyles += 1;
    return { transform: "none" } as CSSStyleDeclaration;
  }) as typeof getComputedStyle;

  try {
    root = createRoot(host);
    await act(async () => root!.render(<Harness />));
    const initial = { queries, rects, computedStyles };
    expect(initial.queries).toBeGreaterThan(0);
    expect(initial.rects).toBeGreaterThan(0);
    expect(initial.computedStyles).toBeGreaterThan(0);
    await act(async () => rerender());
    expect({ queries, rects, computedStyles }).toEqual(initial);
  } finally {
    Element.prototype.querySelectorAll = originalQuerySelectorAll;
    HTMLElement.prototype.getBoundingClientRect = originalGetBoundingClientRect;
    scope.getComputedStyle = originalGetComputedStyle;
    await act(async () => root?.unmount());
    root = undefined;
  }
});

test("observes a replacement list root when its row keys stay the same", async () => {
  const { useListMotion } = await import("../src/agent-session/acpmux/newtab/listMotion");
  let replace!: () => void;
  function Harness() {
    const [version, setVersion] = useState(0);
    const list = useRef<HTMLDivElement>(null);
    replace = () => setVersion((value) => value + 1);
    useListMotion(list, ".row", ["a"]);
    return (
      <div key={version} ref={list}>
        <div className="row" />
      </div>
    );
  }
  const start = observers.length;
  root = createRoot(host);
  try {
    await act(async () => root!.render(<Harness />));
    const first = host.firstElementChild;
    await act(async () => replace());
    const replacement = host.firstElementChild;
    expect(replacement).not.toBe(first);
    const active = observers.slice(start).filter((observer) => observer.target);
    expect(active.length).toBe(1);
    expect(active[0]?.target === replacement).toBe(true);
  } finally {
    await act(async () => root?.unmount());
    root = undefined;
  }
});

test("keeps resize observation after Strict Mode replays effects", async () => {
  const { useListMotion } = await import("../src/agent-session/acpmux/newtab/listMotion");
  function Harness() {
    const list = useRef<HTMLDivElement>(null);
    useListMotion(list, ".row", ["a"]);
    return (
      <div ref={list}>
        <div className="row" />
      </div>
    );
  }
  const start = observers.length;
  root = createRoot(host);
  try {
    await act(async () =>
      root!.render(
        <StrictMode>
          <Harness />
        </StrictMode>,
      ),
    );
    expect(observers.slice(start).some((observer) => observer.disconnects > 0)).toBe(true);
    const active = observers.slice(start).filter((observer) => observer.target);
    expect(active.length).toBe(1);
    expect(active[0]?.target === host.firstElementChild).toBe(true);
  } finally {
    await act(async () => root?.unmount());
    root = undefined;
  }
});

test.each([false, true])("resized rows retain reorder motion with reduced motion %s", async (reduced) => {
  const { useListMotion } = await import("../src/agent-session/acpmux/newtab/listMotion");
  let reorder!: () => void;
  let spacing = 20;
  function Harness() {
    const [keys, setKeys] = useState(["a", "b"]);
    const list = useRef<HTMLDivElement>(null);
    reorder = () => setKeys(["b", "a", "c"]);
    useListMotion(list, ".row", keys);
    return (
      <div ref={list} style={{ "--agent-motion-move": "100ms", "--agent-motion-in": "50ms" } as CSSProperties}>
        {keys.map((key) => (
          <div key={key} className="row" data-key={key} />
        ))}
      </div>
    );
  }
  const originalRect = HTMLElement.prototype.getBoundingClientRect;
  const originalAnimate = HTMLElement.prototype.animate;
  const originalMedia = scope.matchMedia;
  const motions: { key: string | undefined; frames: Keyframe[] }[] = [];
  HTMLElement.prototype.getBoundingClientRect = function () {
    const index = this.dataset.key ? [...this.parentElement!.children].indexOf(this) : 0;
    return new DOMRect(0, index * spacing, 100, spacing);
  };
  HTMLElement.prototype.animate = function (frames) {
    motions.push({ key: this.dataset.key, frames: frames as Keyframe[] });
    return { cancel() {} } as Animation;
  };
  scope.matchMedia = () => ({ matches: reduced });
  const start = observers.length;
  root = createRoot(host);
  try {
    await act(async () => root!.render(<Harness />));
    expect(motions).toEqual([]);
    // A pane resize can change the layout without causing the owner to render.
    spacing = 30;
    observers
      .slice(start)
      .find((observer) => observer.target)
      ?.resize();
    await act(async () => reorder());
    expect(motions).toEqual([
      ...(reduced
        ? []
        : [
            { key: "b", frames: [{ transform: "translate(0px, 30px)" }, { transform: "none" }] },
            { key: "a", frames: [{ transform: "translate(0px, -30px)" }, { transform: "none" }] },
          ]),
      { key: "c", frames: [{ opacity: 0 }, { opacity: 1 }] },
    ]);
  } finally {
    await act(async () => root?.unmount());
    root = undefined;
    HTMLElement.prototype.getBoundingClientRect = originalRect;
    if (originalAnimate) HTMLElement.prototype.animate = originalAnimate;
    else delete (HTMLElement.prototype as Partial<HTMLElement>).animate;
    scope.matchMedia = originalMedia;
  }
});
