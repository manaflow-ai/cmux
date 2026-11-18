import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { Schema } from "@milkdown/kit/prose/model";
import { EditorState } from "@milkdown/kit/prose/state";
import { fieldGrowth, growthHoldsTop } from "../src/agent-session/acpmux/composer/fieldGrowth";
import { FIELD_GROWTH_EVENT, type FieldGrowthEvent } from "../src/agent-session/acpmux/composer/fieldGrowthEvent";
import { teardownDom } from "./support/domTeardown";

const observers = new Set<() => void>();
let callbacks: FrameRequestCallback[] = [];
/** The frame after an edit: its animation callbacks run, then its layout is made and its observers deliver. */
const frame = () => {
  const due = callbacks;
  callbacks = [];
  for (const callback of due) callback(0);
  for (const callback of observers) callback();
};

test("one line grows and shrinks in CSS pixels at every composer zoom", async () => {
  const dom = new JSDOM("<!doctype html><body></body>", { pretendToBeVisual: true });
  const { window } = dom;
  const scope = globalThis as Record<string, unknown>;
  const globals = {
    window,
    document: window.document,
    navigator: window.navigator,
    MutationObserver: window.MutationObserver,
    CustomEvent: window.CustomEvent,
    getComputedStyle: window.getComputedStyle.bind(window),
    // The frame's observer step, run by hand (`frame` below) after each edit.
    ResizeObserver: class {
      constructor(callback: () => void) {
        observers.add(callback);
      }
      observe() {}
      disconnect() {}
    },
    requestAnimationFrame: (callback: FrameRequestCallback) => callbacks.push(callback),
    cancelAnimationFrame: () => {},
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
      // Reads of the field's layout, and in the edit's own task (`editing`): a forced layout per key.
      let editing = false;
      let readsInEdit = 0;
      field.getBoundingClientRect = () => {
        if (editing) readsInEdit += 1;
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
      // The text's own box is as tall as the field's content here: a line typed grows it.
      view.dom.getBoundingClientRect = () => {
        if (editing) readsInEdit += 1;
        return new window.DOMRect(0, 0, 600, Number.parseFloat(field.style.height) * zoom - 8);
      };
      frame();
      /** An edit, in its own task, then the frame that shows it. */
      const edit = (text: string) => {
        editing = true;
        view.dispatch(view.state.tr.insertText(text));
        editing = false;
        frame();
      };
      try {
        for (const height of [68, 48, 68, 48]) {
          const before = Number.parseFloat(field.style.height);
          field.style.height = `${height}px`;
          // The browser may scroll to the new caret before the editor reports its edit.
          field.scrollTop = 20;
          edit("x");
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
          // A second key on the same line reads nothing and keeps the motion; the caret reveal's
          // scroll after it is held at the top.
          const frames0 = frames;
          field.scrollTop = 8;
          edit("y");
          field.dispatchEvent(new window.Event("scroll"));
          expect(field.scrollTop).toBe(0);
          expect(frames).toBe(frames0);
          expect(growthHoldsTop(field)).toBe(true);
          animation!.dispatchEvent(new window.Event("finish"));
          expect(growthHoldsTop(field)).toBe(false);
        }
        // A growth past 1.5 lines, in CSS pixels at every zoom, keeps the caret in view instead.
        field.style.height = "188px";
        edit("large paste");
        expect(growthHoldsTop(field)).toBe(false);
        animation!.dispatchEvent(new window.Event("finish"));
        // At the maximum height, caret reveal and native scrolling remain available.
        capped = true;
        field.style.height = "208px";
        field.scrollTop = 60;
        edit("past the cap");
        expect(growthHoldsTop(field)).toBe(false);
        expect(view.someProp("handleScrollToSelection", (handle) => handle(view))).toBeUndefined();
        expect(field.scrollTop).toBe(60);
        field.scrollTop = 80;
        field.dispatchEvent(new window.Event("scroll"));
        expect(field.scrollTop).toBe(80);
        // No edit read the field's layout in its own task: the frame's observer read it.
        expect(readsInEdit).toBe(0);
      } finally {
        view.destroy();
        field.remove();
      }
    }
  } finally {
    await teardownDom(saved, { window: dom.window, scope });
  }
});
