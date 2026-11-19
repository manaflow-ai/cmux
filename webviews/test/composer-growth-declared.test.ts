// Leo, 2026-11-18: "the things that move we only expect at certain times". The composer's own growth is
// a declared move (schemas/layout-motion/contract.json `composer-growth`) for exactly as long as the field
// moves: its motion's length when it runs on its curve, and the frame it changes in (and the next) when it
// lands at once (an attachment placed, a value set from outside). Nothing stays declared after, so a box
// that grows later on its own (a picture decoding to another size) is still an undeclared move.
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { Schema } from "@milkdown/kit/prose/model";
import { EditorState } from "@milkdown/kit/prose/state";
import { fieldGrowth } from "../src/agent-session/acpmux/composer/fieldGrowth";
import { openDeclarations } from "../src/layout/motionContract";
import { teardownDom } from "./support/domTeardown";

const growth = () => openDeclarations().filter((declaration) => declaration.event === "composer-growth");

test("the field's growth is declared while it moves, and only then", async () => {
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
    ResizeObserver: class {
      observe() {}
      disconnect() {}
    },
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
    const field = window.document.createElement("div");
    field.className = "acpmux-md-field";
    field.style.cssText = "height:48px;line-height:20px;box-sizing:border-box";
    window.document.body.append(field);
    field.getBoundingClientRect = () => new window.DOMRect(0, 0, 600, Number.parseFloat(field.style.height));
    Object.defineProperties(field, {
      clientHeight: { get: () => Number.parseFloat(field.style.height) },
      scrollHeight: { get: () => Number.parseFloat(field.style.height) },
    });
    let animation: Animation | undefined;
    field.animate = () => {
      const events = new window.EventTarget();
      animation = Object.assign(events, {
        startTime: 0,
        cancel: () => queueMicrotask(() => events.dispatchEvent(new window.Event("cancel"))),
      }) as unknown as Animation;
      return animation;
    };
    let external = false;
    const view = new EditorView(field, {
      state: EditorState.create({ schema, plugins: [fieldGrowth(() => external)] }),
    });
    const frame = () => new Promise((resolve) => window.requestAnimationFrame(resolve));
    try {
      // An edit with no change of height declares nothing.
      view.dispatch(view.state.tr.insertText("a"));
      expect(growth()).toHaveLength(0);

      // A value set from outside lands at once, with no motion: declared for its frame and the next,
      // then gone.
      external = true;
      field.style.height = "68px";
      view.dispatch(view.state.tr.insertText("b"));
      expect(animation).toBeUndefined();
      expect(growth()).toHaveLength(1);
      expect(growth()[0]!.scope).toBe("all");
      await frame();
      await frame();
      await frame();
      expect(growth()).toHaveLength(0);

      // A line lost on the field's curve: declared for the motion's length, and lapsed after it.
      external = false;
      field.style.height = "48px";
      view.dispatch(view.state.tr.insertText("c"));
      expect(animation).toBeDefined();
      expect(growth()).toHaveLength(1);
      expect(openDeclarations(performance.now() + 5_000).filter((d) => d.event === "composer-growth")).toHaveLength(0);
      animation!.dispatchEvent(new window.Event("finish"));
    } finally {
      view.destroy();
      field.remove();
    }
  } finally {
    await teardownDom(saved, { window: dom.window, scope });
  }
});
