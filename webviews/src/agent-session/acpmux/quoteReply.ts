// Quote in Reply inserts one undoable block edit after the draft; typing resumes in a paragraph
// outside the quote.
import { parserCtx, remarkCtx, type Editor } from "@milkdown/kit/core";
import { Fragment } from "@milkdown/kit/prose/model";
import { closeHistory } from "@milkdown/kit/prose/history";
import { TextSelection } from "@milkdown/kit/prose/state";
import type { EditorView } from "@milkdown/kit/prose/view";

type ParsedNode = {
  type: string;
  children?: ParsedNode[];
  position?: { start?: { offset?: number } };
};

// A selected code/escaped line can look like a reference definition. Milkdown's inline-links
// plugin removes definitions, so escape only each definition opener before the normal parser runs.
// The source positions keep every surrounding heading, list, code block and paragraph intact.
export function escapeDefinitions(markdown: string, node: ParsedNode): string {
  const offsets: number[] = [];
  const visit = (current: ParsedNode) => {
    if (current.type === "definition") {
      const offset = current.position?.start?.offset;
      if (typeof offset === "number" && markdown[offset] === "[") offsets.push(offset);
    }
    current.children?.forEach(visit);
  };
  visit(node);
  return offsets
    .sort((left, right) => right - left)
    .reduce((source, offset) => source.slice(0, offset) + "\\" + source.slice(offset), markdown);
}

export function insertReplyQuote(made: Editor, current: EditorView, markdown: string) {
  made.action((ctx) => {
    const raw = ctx.get(remarkCtx).parse(markdown) as unknown as ParsedNode;
    const quoted = ctx.get(parserCtx)(escapeDefinitions(markdown, raw));
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
