// The draft's tool badge under the caret and a selection (deeplinkTitles.ts): the word stays text
// while it is typed, but a click, an arrow or a drag keeps the badge whole, and a selection across
// it tints it (Lucas, 2026-11-23: "when trying to select text it looks very weird").
import { expect, test } from "bun:test";
import { Schema } from "@milkdown/kit/prose/model";
import { EditorState, TextSelection } from "@milkdown/kit/prose/state";
import type { Decoration, DecorationSet } from "@milkdown/kit/prose/view";
import { deeplinkTitlesPlugin, type DeeplinkTitles } from "./deeplinkTitles";
import { deeplinkTokensPlugin } from "./deeplinkTokens";

const schema = new Schema({
  nodes: {
    doc: { content: "block+" },
    paragraph: { group: "block", content: "inline*" },
    text: { group: "inline" },
  },
});

const titles: DeeplinkTitles = {
  known: (href) =>
    href.startsWith("cmux-tool:") ? { kind: "workspace", title: "Computer Use", tool: "cu" } : undefined,
  subscribe: () => () => {},
  label: (info) => info.title,
};

const titlesPlugin = deeplinkTitlesPlugin(titles);

// "ask @computer-use now": the word runs from 5 to 18 (the paragraph opens at 1).
const WORD_FROM = 5;
const WORD_TO = 18;

const start = (text = "ask @computer-use now") =>
  EditorState.create({
    schema,
    doc: schema.node("doc", null, [schema.node("paragraph", null, [schema.text(text)])]),
    plugins: [deeplinkTokensPlugin(), titlesPlugin],
  });

const decorations = (state: EditorState): Decoration[] =>
  (titlesPlugin.props.decorations!.call(titlesPlugin, state) as DecorationSet).find();

/// Whether the badge is drawn (its front, the hidden word, and its title end), and if it is selected.
const badge = (state: EditorState) => {
  const found = decorations(state);
  const end = found.find((decoration) => decoration.from === WORD_TO && decoration.to === WORD_TO);
  return {
    drawn: found.length === 3,
    selected: (end?.spec as { selected?: boolean } | undefined)?.selected === true,
  };
};

const select = (state: EditorState, anchor: number, head = anchor) =>
  state.apply(state.tr.setSelection(TextSelection.create(state.doc, anchor, head)));

test("the word stays text while it is typed, the caret at its end", () => {
  let state = start("ask @computer-us");
  state = select(state, WORD_TO - 1);
  state = state.apply(state.tr.insertText("e"));
  expect(state.selection.head).toBe(WORD_TO);
  expect(badge(state).drawn).toBe(false);
});

test("a click or an arrow that puts the caret at the badge's end keeps the badge", () => {
  const state = select(start(), WORD_TO);
  expect(badge(state)).toEqual({ drawn: true, selected: false });
});

test("a drag that starts at the badge's end keeps it, and one across it tints it", () => {
  // From its end leftward into "ask": the badge is inside the selection.
  expect(badge(select(start(), WORD_TO, 2))).toEqual({ drawn: true, selected: true });
  // From its end rightward into "now": the badge is outside it.
  expect(badge(select(start(), WORD_TO, WORD_TO + 3))).toEqual({ drawn: true, selected: false });
  // From its start across it.
  expect(badge(select(start(), WORD_FROM, WORD_TO + 1))).toEqual({ drawn: true, selected: true });
});

test("a selection end set inside the word still brings its text back to edit", () => {
  expect(badge(select(start(), WORD_FROM + 3, WORD_TO + 2)).drawn).toBe(false);
});

test("an edit away from the caret keeps a clicked badge, and a caret put back keeps a typed word", () => {
  // Clicked to the badge's end, then text taken out before it (an attachment, another edit): still a badge.
  let state = select(start(), WORD_TO);
  state = state.apply(state.tr.delete(1, 2));
  expect(state.selection.head).toBe(WORD_TO - 1);
  expect(badge(state).drawn).toBe(true);
  // Typed to its end, then the caret put back where it was (a focus restored): still the typed word.
  state = start("ask @computer-us");
  state = select(state, WORD_TO - 1);
  state = state.apply(state.tr.insertText("e"));
  state = select(state, WORD_TO);
  expect(decorations(state).length).toBe(0);
});
