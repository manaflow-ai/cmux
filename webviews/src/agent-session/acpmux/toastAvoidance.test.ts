import { describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { postNative, setNativeHost } from "./native";
import {
  bottomStackBox,
  elementBox,
  reportToastAvoidance,
  resendToastAvoidance,
  resetToastAvoidanceReports,
  watchToastAvoidance,
  type StackBox,
} from "./toastAvoidance";

// The composer never moves for a toast (Leo 2026-11-07): the page reports its bottom stack and the
// host lifts the toasts above it; no toast band reaches the page's layout.
type Box = { left: number; top: number; width: number; height: number };

function page() {
  const dom = new JSDOM(
    '<!doctype html><html><body><section class="acpmux-shell"><div class="acpmux-main"><div class="acpmux-dock">' +
      '<div class="acpmux-home-area"></div><div class="acpmux-asks-stack"></div><form class="acpmux-composer"></form><div class="acpmux-empty"></div>' +
      "</div></div></section></body></html>",
  );
  const { document } = dom.window;
  const boxes = new Map<Element, Box>();
  const place = (selector: string, box: Box) => boxes.set(document.querySelector(selector)!, box);
  dom.window.Element.prototype.getBoundingClientRect = function (this: Element) {
    const box = boxes.get(this) ?? { left: 0, top: 0, width: 0, height: 0 };
    return { ...box, x: box.left, y: box.top, right: box.left + box.width, bottom: box.top + box.height } as DOMRect;
  };
  return { dom, document, dock: document.querySelector<HTMLElement>(".acpmux-dock")!, place };
}

describe("toast avoidance", () => {
  test("the stack's box is the union of its drawn parts, a new chat's lists left out", () => {
    const { dock, place } = page();
    expect(bottomStackBox(dock)).toBeUndefined();
    place(".acpmux-home-area", { left: 0, top: 100, width: 900, height: 400 });
    place("form.acpmux-composer", { left: 20.4, top: 660.6, width: 860, height: 90 });
    expect(bottomStackBox(dock)).toEqual({ left: 20, top: 661, right: 880, bottom: 751 });
    place(".acpmux-asks-stack", { left: 30, top: 520, width: 840, height: 130 });
    expect(bottomStackBox(dock)).toEqual({ left: 20, top: 520, right: 880, bottom: 751 });
  });

  test("the host hears the box once per change, and none when the stack goes", () => {
    const { dom, dock, place } = page();
    const view = dom.window as unknown as Window & typeof globalThis;
    const resized: (() => void)[] = [];
    (view as any).ResizeObserver = class {
      constructor(callback: () => void) {
        resized.push(callback);
      }
      observe() {}
      disconnect() {}
    };
    const frames: FrameRequestCallback[] = [];
    view.requestAnimationFrame = (callback) => frames.push(callback);
    view.cancelAnimationFrame = () => {};
    const flush = () => frames.splice(0).forEach((callback) => callback(0));
    const sent: (StackBox | undefined)[] = [];
    place("form.acpmux-composer", { left: 20, top: 660, width: 860, height: 90 });
    const stop = watchToastAvoidance(dock, (box) => sent.push(box));
    flush();
    expect(sent).toEqual([{ left: 20, top: 660, right: 880, bottom: 750 }]);
    // A resize that leaves the box where it was says nothing.
    resized.forEach((callback) => callback());
    flush();
    expect(sent.length).toBe(1);
    // The composer grew a line: its new top.
    place("form.acpmux-composer", { left: 20, top: 640, width: 860, height: 110 });
    resized.forEach((callback) => callback());
    flush();
    expect(sent.at(-1)).toEqual({ left: 20, top: 640, right: 880, bottom: 750 });
    stop();
    expect(sent.at(-1)).toBeUndefined();
  });

  test("the newest layout's report is the one the host hears; when it goes, the one under it again", () => {
    const { dom, document, dock, place } = page();
    const view = dom.window as unknown as Window & typeof globalThis;
    (view as any).ResizeObserver = class {
      observe() {}
      disconnect() {}
    };
    const frames: FrameRequestCallback[] = [];
    view.requestAnimationFrame = (callback) => frames.push(callback);
    view.cancelAnimationFrame = () => {};
    const flush = () => frames.splice(0).forEach((callback) => callback(0));
    resetToastAvoidanceReports();
    const heard: unknown[] = [];
    setNativeHost(async (method, params) => {
      if (method === "pane.toastAvoidance") heard.push(params.rects);
    });
    try {
      place("form.acpmux-composer", { left: 20, top: 660, width: 860, height: 90 });
      const chat = reportToastAvoidance(dock);
      flush();
      expect(heard.at(-1)).toEqual([{ left: 20, top: 660, right: 880, bottom: 750 }]);
      // A New Tab composer card mounts over it (the chat's stack stays mounted a moment).
      const card = document.createElement("div");
      document.body.append(card);
      place("body > div", { left: 40, top: 600, width: 820, height: 100 });
      const newTab = reportToastAvoidance(card, elementBox);
      flush();
      expect(heard.at(-1)).toEqual([{ left: 40, top: 600, right: 860, bottom: 700 }]);
      // The chat's stack goes first: the card is still what the toasts avoid.
      chat();
      expect(heard.at(-1)).toEqual([{ left: 40, top: 600, right: 860, bottom: 700 }]);
      newTab();
      expect(heard.at(-1)).toEqual([]);
    } finally {
      setNativeHost(undefined);
      resetToastAvoidanceReports();
    }
  });

  test("a handshake retry clears the host's box; a mounted composer with unchanged bounds is heard again", async () => {
    const { dom, document, place } = page();
    const view = dom.window as unknown as Window & typeof globalThis;
    const resized: (() => void)[] = [];
    (view as any).ResizeObserver = class {
      constructor(callback: () => void) {
        resized.push(callback);
      }
      observe() {}
      disconnect() {}
    };
    const frames: FrameRequestCallback[] = [];
    view.requestAnimationFrame = (callback) => frames.push(callback);
    view.cancelAnimationFrame = () => {};
    const flush = () => frames.splice(0).forEach((callback) => callback(0));
    resetToastAvoidanceReports();
    // The host as AgentPaneHandshakeReply has it: every `ready` (an in-page retry too) clears its box.
    let hostBox: unknown = [];
    setNativeHost(async (method, params) => {
      if (method === "pane.toastAvoidance") hostBox = params.rects;
      if (method === "ready") hostBox = [];
    });
    try {
      // A New Tab stage composer card, mounted.
      const card = document.createElement("div");
      document.body.append(card);
      place("body > div", { left: 40, top: 600, width: 820, height: 100 });
      const stop = reportToastAvoidance(card, elementBox);
      flush();
      const box = [{ left: 40, top: 600, right: 860, bottom: 700 }];
      expect(hostBox).toEqual(box);
      // The handshake retries in the same document; the card has not moved.
      await postNative("ready", { reconnect: true });
      expect(hostBox).toEqual([]);
      resendToastAvoidance();
      expect(hostBox).toEqual(box);
      // Later resizes with the same bounds still leave the host avoiding it.
      resized.forEach((callback) => callback());
      flush();
      expect(hostBox).toEqual(box);
      stop();
      expect(hostBox).toEqual([]);
    } finally {
      setNativeHost(undefined);
      resetToastAvoidanceReports();
    }
  });

  test("the page's handshake resends the toast box once the host answers", () => {
    const app = readFileSync(join(import.meta.dir, "App.tsx"), "utf8");
    expect(app).toMatch(
      />\("ready", reconnect \? \{ reconnect \} : \{\}\)\s*(\/\/[^\n]*\s*)?\.finally\(resendToastAvoidance\)/,
    );
  });

  test("no rule lets a toast band move the shell, the stage or the stack", () => {
    for (const file of ["bottomStack.css", "styles.css", "composerStates.css"]) {
      expect(readFileSync(join(import.meta.dir, file), "utf8")).not.toContain("--cmux-toast-room");
    }
  });
});
