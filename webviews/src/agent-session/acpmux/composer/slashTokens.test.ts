import { describe, expect, test } from "bun:test";
import { Schema, type Node as ProseNode } from "@milkdown/kit/prose/model";
import { history, undo } from "@milkdown/kit/prose/history";
import { EditorState, TextSelection, type Transaction } from "@milkdown/kit/prose/state";
import type { DecorationSet } from "@milkdown/kit/prose/view";
import { slashNames, type SlashCommand } from "../slashCommands";
import { INLINE_NODE } from "./inlineNode";
import { commandEdit, setSlashNames, slashTokensPlugin, slashTriggerAt } from "./slashTokens";

// The prompt editor's shape, as Milkdown's commonmark makes it: paragraphs, headings, line breaks,
// a code block, an inline code mark, and the composer's attachments placed in the text.
const schema = new Schema({
  nodes: {
    doc: { content: "block+" },
    paragraph: { group: "block", content: "inline*" },
    heading: { group: "block", content: "inline*" },
    blockquote: { group: "block", content: "paragraph+" },
    code_block: { group: "block", content: "text*", code: true },
    text: { group: "inline" },
    hardbreak: { group: "inline", inline: true },
    [INLINE_NODE]: { group: "inline", inline: true, atom: true },
  },
  marks: { inlineCode: { code: true } },
});

// cmux's own command, a harness built-in (untagged) and two skills.
const commands: SlashCommand[] = [
  { name: "model", description: "", source: "cmux" },
  { name: "compact", description: "", source: "agent" },
  { name: "review-pr", description: "", source: "skill" },
  { name: "release", description: "", source: "skill" },
];

/// A paragraph's (or heading's) content from a line: "\n" a line break, U+FFFC an attachment.
const inline = (line: string) =>
  line
    .split(/(\n|\uFFFC)/)
    .flatMap((part) =>
      part === "\n"
        ? [schema.node("hardbreak")]
        : part === "\uFFFC"
          ? [schema.node(INLINE_NODE)]
          : part
            ? [schema.text(part)]
            : [],
    );

/// A document from lines: each string a paragraph; one starting `# ` a heading.
function doc(...paragraphs: string[]): ProseNode {
  return schema.node(
    "doc",
    null,
    paragraphs.map((line) =>
      line.startsWith("# ")
        ? schema.node("heading", null, inline(line.slice(2)))
        : schema.node("paragraph", null, inline(line)),
    ),
  );
}

/// The state with the caret where `|` is (taken out of the text; a line break counts as one place).
function state(...paragraphs: string[]): EditorState {
  const made = doc(...paragraphs.map((line) => line.replace("|", "")));
  let at = -1;
  let pos = 0;
  paragraphs.forEach((line, index) => {
    const caret = line.replace(/^# /, "").indexOf("|");
    if (caret >= 0 && at < 0) at = pos + 1 + caret;
    pos += made.child(index).nodeSize;
  });
  return EditorState.create({
    doc: made,
    selection: at >= 0 ? TextSelection.create(made, at) : undefined,
    plugins: [history(), slashTokensPlugin(() => slashNames(commands))],
  });
}

const apply = (current: EditorState, tr: Transaction) => current.apply(tr);

/// The text each command-word decoration covers, in order. Any instance of the plugin reads the
/// state's decorations (they live under its key).
const reader = slashTokensPlugin(() => slashNames([]));
function blue(current: EditorState): string[] {
  const set = reader.props.decorations!.call(reader, current) as DecorationSet;
  return set
    .find()
    .sort((a, b) => a.from - b.from)
    .map((decoration) => current.doc.textBetween(decoration.from, decoration.to));
}

const typeAt = (current: EditorState, text: string) => apply(current, current.tr.insertText(text));

describe("slashTriggerAt: the `/word` the caret ends", () => {
  test("at the start, after a space, after a line break and in a later paragraph", () => {
    expect(slashTriggerAt(state("/re|"))).toEqual({ query: "re", length: 3, leading: true });
    expect(slashTriggerAt(state("fix it /re|"))).toEqual({ query: "re", length: 3, leading: false });
    expect(slashTriggerAt(state("fix it\n/re|"))).toEqual({ query: "re", length: 3, leading: false });
    expect(slashTriggerAt(state("fix it", "/re|"))).toEqual({ query: "re", length: 3, leading: false });
  });

  test("inside a word, a URL, a code block or a code span: none", () => {
    expect(slashTriggerAt(state("src/app|"))).toBeUndefined();
    expect(slashTriggerAt(state("see http://x/y|"))).toBeUndefined();
    const code = EditorState.create({
      doc: schema.node("doc", null, [schema.node("code_block", null, [schema.text("/re")])]),
    });
    expect(slashTriggerAt(code.apply(code.tr.setSelection(TextSelection.create(code.doc, 4))))).toBeUndefined();
    const span = EditorState.create({
      doc: schema.node("doc", null, [
        schema.node("paragraph", null, [schema.text("a /re", [schema.mark("inlineCode")])]),
      ]),
    });
    expect(slashTriggerAt(span.apply(span.tr.setSelection(TextSelection.create(span.doc, 6))))).toBeUndefined();
  });

  test("the caret moving away from the word closes it", () => {
    const open = state("fix /re| now");
    expect(slashTriggerAt(open)?.query).toBe("re");
    const moved = open.apply(open.tr.setSelection(TextSelection.create(open.doc, open.doc.content.size - 1)));
    expect(slashTriggerAt(moved)).toBeUndefined();
    const before = open.apply(open.tr.setSelection(TextSelection.create(open.doc, 5)));
    expect(slashTriggerAt(before)).toBeUndefined();
  });
});

describe("commandEdit: a pick in place", () => {
  test("mid-prompt it writes `/name ` over the word, the text around kept, the caret after it", () => {
    const start = state("fix the build then /re| it");
    const next = apply(start, commandEdit(start, "review-pr")!);
    expect(next.doc.textContent).toBe("fix the build then /review-pr it");
    expect(next.selection.from).toBe(1 + "fix the build then /review-pr ".length);
    expect(slashTriggerAt(next)).toBeUndefined();
  });

  test("one undo takes the pick back, not the letters typed before it", () => {
    let current = state("fix |");
    current = typeAt(current, "/");
    current = typeAt(current, "re");
    current = apply(current, commandEdit(current, "review-pr")!);
    expect(current.doc.textContent).toBe("fix /review-pr ");
    undo(current, (tr) => (current = current.apply(tr)));
    expect(current.doc.textContent).toBe("fix /re");
  });

  test("no `/word` at the caret: no edit", () => {
    expect(commandEdit(state("src/app|"), "review-pr")).toBeUndefined();
  });
});

describe("the command words draw blue", () => {
  test("a valid name at the start or mid-prompt; unknown words, paths and URLs stay plain", () => {
    expect(blue(state("/review-pr then /release"))).toEqual(["/review-pr", "/release"]);
    expect(blue(state("fix /nope and src/review-pr and http://x/release"))).toEqual([]);
  });

  test("cmux's own commands only at the prompt's start", () => {
    expect(blue(state("/model opus"))).toEqual(["/model"]);
    expect(blue(state("then /model"))).toEqual([]);
    expect(blue(state("fix", "/model"))).toEqual([]);
  });

  test("typing follows: a word turns blue when complete and plain when it changes", () => {
    let current = state("fix it |");
    for (const char of "/review-p") current = typeAt(current, char);
    expect(blue(current)).toEqual([]);
    current = typeAt(current, "r");
    expect(blue(current)).toEqual(["/review-pr"]);
    current = typeAt(current, "x");
    expect(blue(current)).toEqual([]);
    current = apply(current, current.tr.delete(current.selection.from - 1, current.selection.from));
    expect(blue(current)).toEqual(["/review-pr"]);
    // Text typed before the `/` makes it part of a word.
    current = apply(current, current.tr.insertText("a", 8));
    expect(blue(current)).toEqual([]);
  });

  test("words put above the first paragraph move its cmux command off the start", () => {
    let current = state("|/model");
    expect(blue(current)).toEqual(["/model"]);
    // A blank line above keeps it first (send trims it), words there do not.
    current = apply(current, current.tr.split(1));
    expect(blue(current)).toEqual(["/model"]);
    current = apply(current, current.tr.insertText("x", 1));
    expect(blue(current)).toEqual([]);
  });

  test("a new command list colours again", () => {
    let current = EditorState.create({
      doc: doc("fix /later"),
      plugins: [slashTokensPlugin(() => slashNames([]))],
    });
    expect(blue(current)).toEqual([]);
    current = apply(
      current,
      setSlashNames(current.tr, slashNames([{ name: "later", description: "", source: "skill" }])),
    );
    expect(blue(current)).toEqual(["/later"]);
  });
});

describe("the prompt's first word, as send reads it", () => {
  test("past a leading attachment, spaces and blank lines: start-only commands count", () => {
    expect(slashTriggerAt(state("\uFFFC /mo|"))).toEqual({ query: "mo", length: 3, leading: true });
    expect(slashTriggerAt(state("", "/mo|"))?.leading).toBe(true);
    expect(slashTriggerAt(state(" \n /mo|"))?.leading).toBe(true);
    expect(blue(state("\uFFFC /model"))).toEqual(["/model"]);
    expect(blue(state("", "  /compact"))).toEqual(["/compact"]);
  });

  test("a heading first is not the prompt's start", () => {
    expect(slashTriggerAt(state("# /mo|"))?.leading).toBe(false);
    expect(blue(state("# /model"))).toEqual([]);
    expect(blue(state("# title", "/model"))).toEqual([]);
  });

  test("a harness built-in mid-prompt stays plain", () => {
    expect(blue(state("fix it then /compact"))).toEqual([]);
    expect(blue(state("/compact then /compact"))).toEqual(["/compact"]);
  });

  test("an edit far before a word that makes it the first, or not, recolours it", () => {
    let current = state(`|x${" ".repeat(300)}/model`);
    expect(blue(current)).toEqual([]);
    current = apply(current, current.tr.delete(1, 2));
    expect(blue(current)).toEqual(["/model"]);
    current = apply(current, current.tr.insertText("y", 1));
    expect(blue(current)).toEqual([]);
    // The first paragraph's words deleted: the next paragraph's word starts the prompt.
    current = state("words", "/model");
    expect(blue(current)).toEqual([]);
    current = apply(current, current.tr.delete(1, 6));
    expect(blue(current)).toEqual(["/model"]);
  });
});

describe("a pick before a long word", () => {
  test("the rest of a word longer than any command is left whole, no surrogate pair split", () => {
    const rest = `${"a".repeat(256)}\u{1F600}`;
    const start = state(`fix /re|${rest}`);
    const next = apply(start, commandEdit(start, "review-pr")!);
    expect(next.doc.textContent).toBe(`fix /review-pr ${rest}`);
    expect(/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/.test(next.doc.textContent)).toBe(
      false,
    );
  });
});

describe("an edit inside a quote", () => {
  test("only the quote's own blocks are read, and its words colour as typed", () => {
    const made = schema.node("doc", null, [
      schema.node("paragraph", null, [schema.text("intro")]),
      schema.node("blockquote", null, [
        schema.node("paragraph", null, [schema.text("one")]),
        schema.node("paragraph", null, [schema.text("fix ")]),
      ]),
    ]);
    let current = EditorState.create({
      doc: made,
      selection: TextSelection.create(made, made.content.size - 2),
      plugins: [slashTokensPlugin(() => slashNames(commands))],
    });
    for (const char of "/release") current = typeAt(current, char);
    expect(blue(current)).toEqual(["/release"]);
    expect(slashTriggerAt(current)).toEqual({ query: "release", length: 8, leading: false });
    expect(slashTriggerAt(typeAt(current, " "))).toBeUndefined();
  });
});
