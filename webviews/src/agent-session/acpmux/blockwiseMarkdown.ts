import { Fragment, type Node as ProseNode } from "@milkdown/kit/prose/model";
import { withTextMarksEscaped } from "./composer/inlineNode";

/// The top-level blocks a prompt's markdown is written block by block from: each writes the same
/// markdown alone as it does in the document, and the document joins them with one blank line.
/// A list does not (two lists in a row are written apart), so a document with one is written whole.
const BLOCKWISE = new Set(["paragraph", "heading", "code_block"]);
const EMPTY_PARAGRAPH = "<br />";
/// Each block's markdown, kept by node, apart for a field with placed attachments (their text is
/// escaped): ProseMirror keeps every block an edit did not touch, so a key writes its own block.
const blockMarkdown = { plain: new WeakMap<ProseNode, string>(), inline: new WeakMap<ProseNode, string>() };

/// A pasted prompt is one paragraph whose lines are hard breaks, so its lines are kept too: each run
/// between breaks, kept by its first node with the nodes it was written from.
const lineMarkdown = { plain: new WeakMap<ProseNode, LineKept>(), inline: new WeakMap<ProseNode, LineKept>() };
type LineKept = { nodes: ProseNode[]; before?: ProseNode; after?: ProseNode; markdown: string };
/// What each kind of hard break writes between two lines, by its attributes.
const breakMarkdown = { plain: new Map<string, string>(), inline: new Map<string, string>() };
/// Stands in for the text beyond a line's breaks while the line is written alone. Escaping reads
/// only the characters next to the break, which the break itself writes, so the line writes the same.
const OUTSIDE = "\uE000";

/** The document's markdown as Milkdown's serializer writes it, from each block's kept markdown
 * when every block allows it, and in a paragraph from each line's. A key into a 200,000-character
 * prompt then writes one line, not the whole prompt (Leo, 2026-11-04: interaction cost stays
 * constant as sessions grow). */
// perf-hot: 2ms composer-draft-typing
export function blockwiseMarkdown(doc: ProseNode, serialize: (doc: ProseNode) => string, inline: boolean): string {
  const write = (node: ProseNode) => serialize(inline ? withTextMarksEscaped(node) : node);
  // The serializer drops an empty paragraph at the end, which alone would write as `<br />`.
  const last = doc.lastChild;
  let blockwise = doc.childCount > 0 && !(last?.type.name === "paragraph" && !last.content.size);
  doc.forEach((block) => {
    // A paragraph that ends in a hard break writes its last newline as the break's own.
    if (!BLOCKWISE.has(block.type.name) || block.lastChild?.type.name === "hardbreak") blockwise = false;
  });
  if (!blockwise) return write(doc);
  if (doc.childCount === 1) {
    const plain = plainLine(doc.child(0));
    if (plain !== undefined) return `${plain}\n`;
    const lines = linewiseMarkdown(doc, doc.child(0), write, inline);
    return lines === undefined ? write(doc) : `${lines}\n`;
  }
  const kept = inline ? blockMarkdown.inline : blockMarkdown.plain;
  const parts: string[] = [];
  doc.forEach((block) => {
    let markdown = kept.get(block);
    if (markdown === undefined) {
      // Alone, an empty paragraph writes nothing; in a document, Milkdown writes it as `<br />`.
      markdown =
        !block.content.size && block.type.name === "paragraph"
          ? EMPTY_PARAGRAPH
          : (plainLine(block) ??
            linewiseMarkdown(doc, block, write, inline) ??
            write(doc.copy(Fragment.from(block))).replace(/\n+$/, ""));
      kept.set(block, markdown);
    }
    parts.push(markdown);
  });
  return `${parts.join("\n\n")}\n`;
}

/// Text the serializer writes unchanged: letters, digits and the punctuation it never escapes
/// mid-line, starting and ending with a letter, digit or that punctuation, never a space.
const PLAIN_LINE = /^[A-Za-z0-9,'?!](?:[A-Za-z0-9 ,'?!.]*[A-Za-z0-9,'?!.])?$/;
/// What would make the serializer escape a `.` in such text: a list number at the start (`1.`),
/// or an autolink literal's `www.` (GFM escapes the dot after a `w` that a word character follows).
const ESCAPED_DOT = /^\d+\.|[Ww]\.[\w.-]/;

/** One paragraph of plain prose, unmarked, as its text: what the serializer writes for it, without
 * running the serializer, which every key into such a prompt ran (Milkdown's whole remark pipeline
 * for one line; composer-typing bench --profile). Undefined for anything else. */
function plainLine(paragraph: ProseNode): string | undefined {
  if (paragraph.type.name !== "paragraph" || !paragraph.childCount) return undefined;
  let text = "";
  for (let at = 0; at < paragraph.childCount; at += 1) {
    const child = paragraph.child(at);
    if (!child.isText || child.marks.length) return undefined;
    text += child.text!;
  }
  return PLAIN_LINE.test(text) && !ESCAPED_DOT.test(text) ? text : undefined;
}

/** A paragraph with hard breaks, written line by line from each line's kept markdown, or undefined
 * when it has none or a break carries marks (a mark across a break is written around both lines). */
function linewiseMarkdown(
  doc: ProseNode,
  paragraph: ProseNode,
  write: (node: ProseNode) => string,
  inline: boolean,
): string | undefined {
  if (paragraph.type.name !== "paragraph") return undefined;
  const lines: ProseNode[][] = [[]];
  const breaks: ProseNode[] = [];
  let plain = true;
  paragraph.forEach((child) => {
    if (child.type.name !== "hardbreak") return void lines.at(-1)!.push(child);
    if (child.marks.length) plain = false;
    breaks.push(child);
    lines.push([]);
  });
  // A break that ends the paragraph is written apart from its lines, so that paragraph is written whole.
  if (!breaks.length || !plain || !lines.at(-1)!.length) return undefined;
  const kept = inline ? lineMarkdown.inline : lineMarkdown.plain;
  const outside = paragraph.type.schema.text(OUTSIDE);
  const writeParagraph = (nodes: ProseNode[]) =>
    write(doc.copy(Fragment.from(paragraph.copy(Fragment.fromArray(nodes)))));
  const separators = inline ? breakMarkdown.inline : breakMarkdown.plain;
  const separator = (hardbreak: ProseNode) => {
    const key = JSON.stringify(hardbreak.attrs);
    let written = separators.get(key);
    if (written === undefined) {
      written = writeParagraph([outside, hardbreak, outside]);
      written =
        written.startsWith(OUTSIDE) && written.endsWith(`${OUTSIDE}\n`)
          ? written.slice(OUTSIDE.length, -OUTSIDE.length - 1)
          : "";
      separators.set(key, written);
    }
    return written;
  };
  let markdown = "";
  for (let at = 0; at < lines.length; at += 1) {
    const nodes = lines[at]!;
    // The breaks around a line are part of what it was written from: a paragraph's edges escape apart.
    const before = at > 0 ? breaks[at - 1]! : undefined;
    const after = at < breaks.length ? breaks[at]! : undefined;
    // An empty line (two breaks in a row) is kept by the break after it, which no other line keys.
    const key = nodes[0] ?? after;
    const known = key && kept.get(key);
    let line: string;
    if (
      known &&
      known.before === before &&
      known.after === after &&
      known.nodes.length === nodes.length &&
      known.nodes.every((node, i) => node === nodes[i])
    )
      line = known.markdown;
    else {
      const prefix = before ? `${OUTSIDE}${separator(before)}` : "";
      const suffix = `${after ? `${separator(after)}${OUTSIDE}` : ""}\n`;
      const written = writeParagraph([
        ...(before ? [outside, before] : []),
        ...nodes,
        ...(after ? [after, outside] : []),
      ]);
      // Anything but the breaks written around the line means it did not write apart.
      if (
        (before && !separator(before)) ||
        (after && !separator(after)) ||
        !written.startsWith(prefix) ||
        !written.endsWith(suffix) ||
        written.length < prefix.length + suffix.length
      )
        return undefined;
      line = written.slice(prefix.length, written.length - suffix.length);
      if (key) kept.set(key, { nodes, before, after, markdown: line });
    }
    markdown += at > 0 ? `${separator(breaks[at - 1]!)}${line}` : line;
  }
  return markdown;
}
