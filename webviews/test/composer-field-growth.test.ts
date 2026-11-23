import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { Schema } from "@milkdown/kit/prose/model";
import { EditorState } from "@milkdown/kit/prose/state";
import { fieldGrowth, growthHoldsTop } from "../src/agent-session/acpmux/composer/fieldGrowth";
import { FIELD_GROWTH_EVENT, type FieldGrowthEvent } from "../src/agent-session/acpmux/composer/fieldGrowthEvent";
import { teardownDom } from "./support/domTeardown";

test("one line grows and shrinks in CSS pixels at every composer zoom", async () => {
  const dom = new JSDOM("<!doctype html><body></body>", { pretendToBeVisual: true });
  const { window } = dom;
  const scope = globalThis as Record<string, unknown>;
  type ResizeCallback = (entries: ResizeObserverEntry[]) => void;
  const resizeObservers = new Set<{ callback: ResizeCallback }>();
  class TestResizeObserver {
    constructor(readonly callback: ResizeCallback) {
      resizeObservers.add(this);
    }
    observe() {}
    disconnect() {
      resizeObservers.delete(this);
    }
  }
  // Frames run when the test says, so the edit's wait for its observer is counted in frames.
  let rafQueue = new Map<number, FrameRequestCallback>();
  let rafId = 0;
  const runFrame = () => {
    const due = rafQueue;
    rafQueue = new Map();
    for (const callback of due.values()) callback(0);
  };
  const globals = {
    window,
    requestAnimationFrame: (callback: FrameRequestCallback) => {
      rafId += 1;
      rafQueue.set(rafId, callback);
      return rafId;
    },
    cancelAnimationFrame: (id: number) => rafQueue.delete(id),
    document: window.document,
    navigator: window.navigator,
    MutationObserver: window.MutationObserver,
    CustomEvent: window.CustomEvent,
    getComputedStyle: window.getComputedStyle.bind(window),
    ResizeObserver: TestResizeObserver,
  };
  const saved = Object.keys(globals).map((key) => [key, key in scope, scope[key]] as const);
  Object.assign(scope, globals);
  try {
    const { EditorView } = await import("@milkdown/kit/prose/view");
    const schema = new Schema({
      nodes: {
        doc: { content: "paragraph+" },
        paragraph: { content: "text*", toDOM: () => ["p", 0] },
        text: {},
      },
    });
    for (const zoom of [0.8, 0.9, 1, 1.1, 1.2]) {
      const field = window.document.createElement("div");
      field.className = "acpmux-md-field";
      field.style.cssText = "height:48px;line-height:20px;box-sizing:border-box";
      window.document.body.append(field);
      let rectReads = 0;
      field.getBoundingClientRect = () => {
        rectReads += 1;
        return new window.DOMRect(0, 0, 600, Number.parseFloat(field.style.height) * zoom);
      };
      let capped = false;
      Object.defineProperties(field, {
        clientHeight: { get: () => Number.parseFloat(field.style.height) },
        scrollHeight: { get: () => Number.parseFloat(field.style.height) + (capped ? 100 : 0) },
      });
      let frames: Keyframe[] = [];
      let animation: Animation;
      field.animate = (keyframes) => {
        frames = keyframes as Keyframe[];
        const events = new window.EventTarget();
        animation = Object.assign(events, {
          startTime: 0,
          cancel: () => queueMicrotask(() => events.dispatchEvent(new window.Event("cancel"))),
        }) as unknown as Animation;
        return animation;
      };
      let target = 0;
      field.addEventListener(FIELD_GROWTH_EVENT, (event) => (target = (event as FieldGrowthEvent).detail.to));
      const view = new EditorView(field, {
        state: EditorState.create({ schema, plugins: [fieldGrowth(() => false)] }),
      });
      const notifyResize = () => {
        const entry = { target: field } as unknown as ResizeObserverEntry;
        for (const observer of Array.from(resizeObservers)) observer.callback([entry]);
      };
      try {
        for (const height of [68, 48, 68, 48]) {
          const before = Number.parseFloat(field.style.height);
          field.style.height = `${height}px`;
          // The browser may scroll to the new caret before the editor reports its edit.
          const beforeDispatchReads = rectReads;
          field.scrollTop = 20;
          view.dispatch(view.state.tr.insertText("x"));
          // Stable-height typing does not force a layout read. A changed height is picked up by
          // ResizeObserver before the frame paints.
          expect(rectReads).toBe(beforeDispatchReads);
          // The frame after the edit: its rAF callbacks run before its observers.
          runFrame();
          notifyResize();
          expect(field.scrollTop).toBe(0);
          expect(Number.parseFloat(String(frames[0]!.height)) * zoom).toBeCloseTo(before * zoom);
          expect(Number.parseFloat(String(frames.at(-1)!.height)) * zoom).toBeCloseTo(height * zoom);
          expect(target).toBeCloseTo(height * zoom);
          // One line keeps its top, rather than scrolling to reveal the caret during growth.
          expect(growthHoldsTop(field)).toBe(true);
          expect(view.someProp("handleScrollToSelection", (handle) => handle(view))).toBe(true);
          // Native caret scrolling can also run after the transaction, during the animation.
          field.scrollTop = 12;
          field.dispatchEvent(new window.Event("scroll"));
          expect(field.scrollTop).toBe(0);
          // A second key on the same line retargets without restoring the old scroll offset.
          field.scrollTop = 8;
          view.dispatch(view.state.tr.insertText("y"));
          expect(field.scrollTop).toBe(0);
          expect(growthHoldsTop(field)).toBe(true);
          animation!.dispatchEvent(new window.Event("finish"));
          expect(growthHoldsTop(field)).toBe(false);
        }
        // A resize that is no edit's (a window rewrap, frames after the last key) moves nothing.
        view.dispatch(view.state.tr.insertText("z"));
        runFrame();
        runFrame();
        frames = [];
        field.style.height = "88px";
        notifyResize();
        expect(frames).toEqual([]);
        expect(growthHoldsTop(field)).toBe(false);
        field.style.height = "48px";
        notifyResize();
        // A growth past 1.5 lines, in CSS pixels at every zoom, keeps the caret in view instead.
        field.style.height = "188px";
        view.dispatch(view.state.tr.insertText("large paste"));
        notifyResize();
        expect(growthHoldsTop(field)).toBe(false);
        animation!.dispatchEvent(new window.Event("finish"));
        // At the maximum height, caret reveal and native scrolling remain available.
        capped = true;
        field.style.height = "208px";
        field.scrollTop = 60;
        view.dispatch(view.state.tr.insertText("past the cap"));
        notifyResize();
        expect(growthHoldsTop(field)).toBe(false);
        expect(view.someProp("handleScrollToSelection", (handle) => handle(view))).toBeUndefined();
        expect(field.scrollTop).toBe(60);
        field.scrollTop = 80;
        field.dispatchEvent(new window.Event("scroll"));
        expect(field.scrollTop).toBe(80);
      } finally {
        view.destroy();
        field.remove();
      }
    }
  } finally {
    await teardownDom(saved, { window: dom.window, scope });
  }
});
