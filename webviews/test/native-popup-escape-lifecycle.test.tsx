import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { useEscapingPopup, type PopupHost } from "../src/ui/popupHost";
import { inspectNativePopups, type NativePresentation, type SurfaceSemantics } from "./helpers/nativePopupGuard";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

test.each(["shown", "rejected"] as const)(
  "observes the real escape hook before and after native %s",
  async (outcome) => {
    dom = new JSDOM(
      '<!doctype html><main id="root"></main><div id="shell" style="position:fixed;z-index:9"><div id="menu" role="menu"><button role="menuitem">Choose</button></div></div>',
      { pretendToBeVisual: true },
    );
    const document = dom.window.document;
    const frames = new Map<number, FrameRequestCallback>();
    let serial = 0;
    const replacements: Record<string, unknown> = {
      window: dom.window,
      document,
      navigator: dom.window.navigator,
      HTMLElement: dom.window.HTMLElement,
      Element: dom.window.Element,
      Node: dom.window.Node,
      MutationObserver: dom.window.MutationObserver,
      getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
      innerHeight: 100,
      innerWidth: 500,
      IS_REACT_ACT_ENVIRONMENT: true,
      requestAnimationFrame: (callback: FrameRequestCallback) => {
        frames.set(++serial, callback);
        return serial;
      },
      cancelAnimationFrame: (id: number) => frames.delete(id),
    };
    for (const key of Object.keys(replacements)) saved.set(key, scope[key]);
    Object.assign(scope, replacements);
    const menu = document.getElementById("menu")!;
    const shell = document.getElementById("shell")!;
    Object.defineProperty(menu, "offsetHeight", { value: 120 });
    let owner: object | null = null;
    let answer: ((reply: { shown: boolean }) => void) | undefined;
    const host: PopupHost = {
      show(_model, nextOwner) {
        owner = nextOwner;
        return new Promise((resolve) => {
          answer = resolve;
        });
      },
      update() {},
      hide() {
        owner = null;
      },
      owner: () => owner,
      listen: () => () => {},
    };
    const anchor = () => ({
      getBoundingClientRect: () => ({ left: 0, right: 100, top: 40, bottom: 60 }),
    });
    function Consumer() {
      useEscapingPopup(host, menu, anchor, { side: "bottom", align: "start", gap: 4 });
      return null;
    }
    root = createRoot(document.getElementById("root")!);
    await act(async () => root!.render(<Consumer />));
    expect(frames.size).toBeGreaterThan(0);
    await act(async () => {
      const pending = [...frames.values()];
      frames.clear();
      for (const callback of pending) callback(0);
    });
    expect(answer).toBeDefined();
    expect(owner).not.toBeNull();
    const mountedOwner = owner!;
    const expected = { popupId: "hook-menu", revision: 1, owner: mountedOwner };
    const semantics = new Map<Element, SurfaceSemantics>();
    const observe = (state: NativePresentation["state"]) => {
      semantics.set(menu, {
        kind: "escape-mirror",
        shell,
        expected,
        presentation: { ...expected, host: "WebPopupHost", state },
      });
      return inspectNativePopups(document, {
        adapter: "native",
        lifecycle: "escape-compatible",
        semantics,
      });
    };
    expect(shell.hasAttribute("data-escaped")).toBe(true);
    expect(observe("pending")).toEqual([]);
    expect(
      inspectNativePopups(document, { adapter: "native", semantics }).some((item) => item.kind === "dom-popup"),
    ).toBe(true);
    await act(async () => answer!({ shown: outcome === "shown" }));
    expect(shell.hasAttribute("data-escaped")).toBe(outcome === "shown");
    if (outcome === "rejected") expect(owner).toBeNull();
    else expect(owner === mountedOwner).toBe(true);
    expect(observe(outcome)).toEqual([]);
    expect(menu.isConnected).toBe(true);
  },
);
