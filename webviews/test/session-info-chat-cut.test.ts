// Session Info's box is cut out of the transcript where they overlap (session-info/chatCut.ts), so
// nothing scrolls behind it (Leo, 2026-11-03: "the session info thing not flicker EVER when im
// scrolling"); where they do not overlap, the transcript keeps its whole box.
import { expect, test } from "bun:test";
import { chatCut } from "../src/agent-session/acpmux/session-info/chatCut";

const scroller = { left: 100, top: 44, right: 900, bottom: 744 };

test("the panel over the chat's right side is a hole in the scroller's own px", () => {
  expect(chatCut(scroller, { left: 560, top: 56, right: 888, bottom: 400.25 })).toBe(
    "polygon(evenodd, 0 0, 100% 0, 100% 100%, 0 100%, 0 0, 460px 12px, 460px 356.5px, 788px 356.5px, 788px 12px, 460px 12px)",
  );
});

test("a panel reaching past the scroller is cut only where it overlaps", () => {
  expect(chatCut(scroller, { left: 700, top: 0, right: 1000, bottom: 300 })).toBe(
    "polygon(evenodd, 0 0, 100% 0, 100% 100%, 0 100%, 0 0, 600px 0px, 600px 256px, 800px 256px, 800px 0px, 600px 0px)",
  );
});

test("a panel beside the transcript cuts nothing", () => {
  expect(chatCut(scroller, { left: 900, top: 56, right: 1200, bottom: 400 })).toBeUndefined();
  expect(chatCut(scroller, { left: 600, top: 744, right: 800, bottom: 900 })).toBeUndefined();
});

// Lucas, 2026-11-06: "when first opening the show more, there is a weird animation glitch, as the window
// expands". WebKit told the ResizeObserver a frame or two late, so the chat showed through the grown
// panel. A section added to the panel now re-measures the cut before it paints.
test("a section added to the panel re-measures the cut without waiting for the ResizeObserver", async () => {
  const { JSDOM } = await import("jsdom");
  const dom = new JSDOM(
    '<div class="acpmux-shell"><div class="acpmux-main"><div class="acpmux-scroll"></div></div><aside></aside></div>',
  );
  const scope = globalThis as Record<string, unknown>;
  const saved = ["window", "document", "ResizeObserver", "MutationObserver", "IS_REACT_ACT_ENVIRONMENT"].map(
    (key) => [key, scope[key]] as const,
  );
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    // Never tells: the cut must not depend on it.
    ResizeObserver: class {
      observe() {}
      disconnect() {}
    },
    MutationObserver: dom.window.MutationObserver,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  try {
    const { act, createElement, useRef, useLayoutEffect } = await import("react").then((react) => ({
      act: react.act,
      createElement: react.createElement,
      useRef: react.useRef,
      useLayoutEffect: react.useLayoutEffect,
    }));
    const { createRoot } = await import("react-dom/client");
    const { useChatCut, CHAT_CUT } = await import("../src/agent-session/acpmux/session-info/chatCut");
    const doc = dom.window.document;
    const shell = doc.querySelector<HTMLElement>(".acpmux-shell")!;
    const aside = doc.querySelector<HTMLElement>("aside")!;
    let bottom = 300;
    const box = (left: number, top: number, right: number, b: number) =>
      ({ left, top, right, bottom: b, width: right - left, height: b - top, x: left, y: top }) as DOMRect;
    doc.querySelector<HTMLElement>(".acpmux-scroll")!.getBoundingClientRect = () => box(0, 0, 1000, 800);
    aside.getBoundingClientRect = () => box(600, 0, 920, bottom);
    function Probe() {
      const frame = useRef<HTMLElement | null>(null);
      useLayoutEffect(() => {
        frame.current = aside;
      });
      frame.current = aside;
      useChatCut(frame, true, "");
      return null;
    }
    const root = createRoot(doc.createElement("div"));
    await act(async () => root.render(createElement(Probe)));
    expect(shell.style.getPropertyValue(CHAT_CUT)).toContain("600px 300px");
    bottom = 450;
    aside.append(doc.createElement("section"));
    await Promise.resolve();
    expect(shell.style.getPropertyValue(CHAT_CUT)).toContain("600px 450px");
    await act(async () => root.unmount());
  } finally {
    for (const [key, value] of saved) scope[key] = value;
    dom.window.close();
  }
});
