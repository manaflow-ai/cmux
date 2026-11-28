// Goal typing-latency: a typed key's caret scroll (a synchronous layout in WebKit) runs in the
// frame that draws the key, not in the key's own task; a selection's scroll stays immediate.
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { Schema } from "@milkdown/kit/prose/model";
import { EditorState, Plugin, TextSelection } from "@milkdown/kit/prose/state";
import { teardownDom } from "./support/domTeardown";
import { importWithDom } from "./support/importWithDom";

const { frameCaretScroll } = await importWithDom(() => import("../src/agent-session/acpmux/composer/frameCaretScroll"));

test("a typed key scrolls the caret into view on the next frame, once; a selection at once", async () => {
  const dom = new JSDOM("<!doctype html><body></body>", { pretendToBeVisual: true });
  const { window } = dom;
  const scope = globalThis as Record<string, unknown>;
  let frames = new Map<number, FrameRequestCallback>();
  let frameId = 0;
  const runFrame = () => {
    const due = frames;
    frames = new Map();
    for (const callback of due.values()) callback(0);
  };
  const globals = {
    window,
    requestAnimationFrame: (callback: FrameRequestCallback) => {
      frameId += 1;
      frames.set(frameId, callback);
      return frameId;
    },
    cancelAnimationFrame: (id: number) => frames.delete(id),
    document: window.document,
    navigator: window.navigator,
    MutationObserver: window.MutationObserver,
    getComputedStyle: window.getComputedStyle.bind(window),
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
    // ProseMirror's own scroll, the one that lays the field out: counted here instead of run.
    let scrolls = 0;
    const counted = new Plugin({
      props: {
        handleScrollToSelection: () => {
          scrolls += 1;
          return true;
        },
      },
    });
    const field = window.document.createElement("div");
    window.document.body.append(field);
    const view = new EditorView(field, {
      state: EditorState.create({ schema, plugins: [frameCaretScroll(), counted] }),
    });
    try {
      view.focus();
      const type = (text: string) => view.dispatch(view.state.tr.insertText(text).scrollIntoView());
      type("h");
      type("i");
      // Two keys before the frame: no scroll in either key, one in the frame.
      expect(scrolls).toBe(0);
      expect(frames.size).toBe(1);
      runFrame();
      expect(scrolls).toBe(1);
      expect(frames.size).toBe(0);
      // A selection's scroll is not deferred.
      view.dispatch(
        view.state.tr
          .setSelection(TextSelection.create(view.state.doc, 1, view.state.doc.content.size - 1))
          .scrollIntoView(),
      );
      expect(scrolls).toBe(2);
      expect(frames.size).toBe(0);
      // A view destroyed before its frame does not scroll.
      view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, 1)));
      type("!");
      expect(frames.size).toBe(1);
    } finally {
      view.destroy();
      field.remove();
    }
    expect(frames.size).toBe(0);
    runFrame();
    expect(scrolls).toBe(2);
  } finally {
    await teardownDom(saved, { window: dom.window, scope });
  }
});
