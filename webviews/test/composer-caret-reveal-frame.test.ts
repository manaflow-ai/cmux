// A key typed in the prompt reveals its caret in the next frame, not in the key's own task (goal
// typing-latency; Leo: "A key typed in a cmux NEXT agent chat has its edit and render done within
// 4 ms"). ProseMirror's reveal reads the caret's rect and every ancestor's box, forcing the edit's
// layout inside the key's task; composer/caretInView.ts runs the same reveal in the frame's
// animation-frame callback instead, once for all keys of that frame. A node or range selection keeps
// the reveal in the edit. The caret still ends in view: composer-draft-overflow.test.ts reads it in
// real Chromium and WebKit as the next frame paints it.
import { afterEach, expect, test } from "bun:test";
import { Schema } from "@milkdown/kit/prose/model";
import { EditorState, NodeSelection, TextSelection } from "@milkdown/kit/prose/state";
import type { EditorView } from "@milkdown/kit/prose/view";
import { caretInView, revealInFrame } from "../src/agent-session/acpmux/composer/caretInView";

const schema = new Schema({
  nodes: {
    doc: { content: "block+" },
    paragraph: { group: "block", content: "text*", toDOM: () => ["p", 0] },
    rule: { group: "block", toDOM: () => ["hr"] },
    text: {},
  },
});

const scope = globalThis as Record<string, unknown>;
const savedFrame = scope.requestAnimationFrame;
let frames: FrameRequestCallback[] = [];
const runFrame = () => {
  const due = frames;
  frames = [];
  for (const callback of due) callback(0);
};
afterEach(() => {
  scope.requestAnimationFrame = savedFrame;
  frames = [];
});

/** A view as ProseMirror's reveal sees it, its reveal counted. */
function fakeView(state: EditorState) {
  const view = {
    state,
    isDestroyed: false,
    reveals: 0,
    dom: { closest: () => null },
    scrollToSelection() {
      // ProseMirror asks its handlers first; one that takes the reveal again would loop.
      if (revealInFrame(view as unknown as EditorView)) return;
      view.reveals += 1;
    },
  };
  return view;
}

test("a caret in text reveals once in the next frame, for every key of that frame", () => {
  scope.requestAnimationFrame = (callback: FrameRequestCallback) => frames.push(callback);
  const doc = schema.node("doc", null, [schema.node("paragraph", null, [schema.text("hello")])]);
  const view = fakeView(EditorState.create({ doc, selection: TextSelection.create(doc, 6) }));
  const asView = view as unknown as EditorView;
  // Three keys in one frame: none reveals in its own task.
  for (let key = 0; key < 3; key++) expect(revealInFrame(asView)).toBe(true);
  expect(view.reveals).toBe(0);
  expect(frames.length).toBe(1);
  runFrame();
  expect(view.reveals).toBe(1);
  // The next key waits for its own frame.
  expect(revealInFrame(asView)).toBe(true);
  view.isDestroyed = true;
  runFrame();
  expect(view.reveals).toBe(1);
});

test("a node selection, a range, or an engine with no frames reveals in the edit", () => {
  scope.requestAnimationFrame = (callback: FrameRequestCallback) => frames.push(callback);
  const doc = schema.node("doc", null, [schema.node("paragraph", null, [schema.text("hello")]), schema.node("rule")]);
  const node = fakeView(EditorState.create({ doc, selection: NodeSelection.create(doc, 7) }));
  expect(revealInFrame(node as unknown as EditorView)).toBe(false);
  const range = fakeView(EditorState.create({ doc, selection: TextSelection.create(doc, 1, 4) }));
  expect(revealInFrame(range as unknown as EditorView)).toBe(false);
  scope.requestAnimationFrame = undefined;
  const caret = fakeView(EditorState.create({ doc, selection: TextSelection.create(doc, 3) }));
  expect(revealInFrame(caret as unknown as EditorView)).toBe(false);
  expect(frames.length).toBe(0);
});

test("the composer's plugin takes ProseMirror's reveal for a caret in text", () => {
  scope.requestAnimationFrame = (callback: FrameRequestCallback) => frames.push(callback);
  const doc = schema.node("doc", null, [schema.node("paragraph", null, [schema.text("hi")])]);
  const view = fakeView(EditorState.create({ doc, selection: TextSelection.create(doc, 3) }));
  const handle = caretInView(12).props.handleScrollToSelection!;
  expect(handle.call(undefined as never, view as unknown as EditorView)).toBe(true);
  runFrame();
  expect(view.reveals).toBe(1);
});
