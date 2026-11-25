// The draft's tool badges (CMUX-682): each `@computer-use` / `@browser-use` word is marked for the
// titles plugin (deeplinkTitles.ts), which draws it as the tool's badge, the way a cmux link is
// marked. Inside inline code or a code block it stays text, as the send reads it.
import { expect, test } from "bun:test";
import { Schema } from "@milkdown/kit/prose/model";
import { EditorState } from "@milkdown/kit/prose/state";
import type { DecorationSet } from "@milkdown/kit/prose/view";
import { deeplinkTokensPlugin, deeplinksKey } from "./deeplinkTokens";

const schema = new Schema({
  nodes: {
    doc: { content: "block+" },
    paragraph: { group: "block", content: "inline*" },
    code_block: { group: "block", content: "text*", code: true },
    text: { group: "inline" },
  },
  marks: { inlineCode: { code: true } },
});

const marked = (doc: ReturnType<typeof schema.node>) => {
  const state = EditorState.create({ schema, doc, plugins: [deeplinkTokensPlugin()] });
  const set = deeplinksKey.getState(state) as DecorationSet;
  return set.find().map((decoration) => ({
    text: state.doc.textBetween(decoration.from, decoration.to),
    href: (decoration.spec as { deeplink?: string }).deeplink,
  }));
};

test("each tool word is marked for its badge; in code it stays text", () => {
  const doc = schema.node("doc", null, [
    schema.node("paragraph", null, [schema.text("open it with @computer-use, then @browser-use")]),
    schema.node("paragraph", null, [
      schema.text("literal "),
      schema.text("@computer-use", [schema.mark("inlineCode")]),
    ]),
    schema.node("code_block", null, [schema.text("@browser-use")]),
  ]);
  expect(marked(doc)).toEqual([
    { text: "@computer-use", href: "cmux-tool:computer-use" },
    { text: "@browser-use", href: "cmux-tool:browser-use" },
  ]);
});
