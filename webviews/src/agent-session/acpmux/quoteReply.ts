// Quote in Reply inserts one undoable block edit after the draft; typing resumes in a paragraph
// outside the quote.
import { parserCtx, remarkCtx, type Editor } from "@milkdown/kit/core";
import { Fragment } from "@milkdown/kit/prose/model";
import { closeHistory } from "@milkdown/kit/prose/history";
import { TextSelection } from "@milkdown/kit/prose/state";
import type { EditorView } from "@milkdown/kit/prose/view";

type ParsedNode = { type: string; children?: ParsedNode[] };

const hasDefinition = (node: ParsedNode): boolean =>
  node.type === "definition" || (node.children?.some(hasDefinition) ?? false);

// A selected code/escaped line can look like a reference definition. Milkdown's inline-links
// plugin removes definitions, so keep that selection literal before its parser runs the plugin.
function literalQuote(current: EditorView, markdown: string) {
  const { schema } = current.state;
  const lines = markdown.replace(/\n+$/, "").split("\n");
  const text = lines.flatMap((line, index) => {
    const value = line.replace(/^>[ \t]?/, "");
    return [...(index ? [schema.nodes.hardbreak.create()] : []), ...(value ? [schema.text(value)] : [])];
  });
  return schema.nodes.blockquote.create(null, schema.nodes.paragraph.create(null, text));
}

export function insertReplyQuote(made: Editor, current: EditorView, markdown: string) {
  made.action((ctx) => {
    const raw = ctx.get(remarkCtx).parse(markdown) as unknown as ParsedNode;
    const quoted = hasDefinition(raw) ? literalQuote(current, markdown) : ctx.get(parserCtx)(markdown);
    if (!quoted) return;
    let content = quoted.type === current.state.schema.nodes.blockquote ? Fragment.from(quoted) : quoted.content;
    const { doc, schema } = current.state;
    // Always leave an empty paragraph after the quote. The native menu normally sends a trailing
    // blank line, but the composer API also guarantees a safe typing target for direct callers.
    const lastQuoted = content.lastChild;
    if (lastQuoted?.type !== schema.nodes.paragraph || lastQuoted.content.size)
      content = content.append(Fragment.from(schema.nodes.paragraph.create()));
    const tr = closeHistory(current.state.tr);
    // Append outside a final quote/list, reusing an empty reply paragraph. A selection in the
    // existing draft never replaces it: Quote in Reply always lands at the bottom.
    const last = doc.lastChild;
    const from =
      last?.type === schema.nodes.paragraph && !last.content.size ? doc.content.size - last.nodeSize : doc.content.size;
    tr.replaceWith(from, doc.content.size, content);
    tr.setSelection(TextSelection.near(tr.doc.resolve(from + content.size), -1));
    current.dispatch(tr.scrollIntoView());
    current.focus();
  });
}
