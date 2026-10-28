// Quote in Reply inserts one undoable block edit after the draft; typing resumes in a paragraph
// outside the quote.
import { parserCtx, type Editor } from "@milkdown/kit/core";
import { Fragment } from "@milkdown/kit/prose/model";
import { closeHistory } from "@milkdown/kit/prose/history";
import { TextSelection } from "@milkdown/kit/prose/state";
import type { EditorView } from "@milkdown/kit/prose/view";

export function insertReplyQuote(made: Editor, current: EditorView, markdown: string) {
  made.action((ctx) => {
    const quoted = ctx.get(parserCtx)(markdown);
    if (!quoted) return;
    let content = quoted.content;
    const { doc, schema } = current.state;
    // Always leave an empty paragraph after the quote. The native menu normally sends a trailing
    // blank line, but the composer API also guarantees a safe typing target for direct callers.
    if (quoted.lastChild?.type !== schema.nodes.paragraph || quoted.lastChild.content.size)
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
