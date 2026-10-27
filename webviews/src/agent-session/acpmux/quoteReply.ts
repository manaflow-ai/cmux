// Quote in Reply inserts one undoable block edit. A transcript quote follows the draft unless
// its editor owns a caret; typing resumes in a paragraph outside the quote.
import { parserCtx, type Editor } from "@milkdown/kit/core";
import { Fragment, Slice } from "@milkdown/kit/prose/model";
import { closeHistory } from "@milkdown/kit/prose/history";
import { TextSelection } from "@milkdown/kit/prose/state";
import type { EditorView } from "@milkdown/kit/prose/view";

export function insertReplyQuote(made: Editor, current: EditorView, markdown: string) {
  made.action((ctx) => {
    const quoted = ctx.get(parserCtx)(markdown);
    if (!quoted) return;
    let content = quoted.content;
    const { doc, schema } = current.state;
    if (/\n[ \t]*\n$/.test(markdown) && quoted.lastChild?.type !== schema.nodes.paragraph)
      content = content.append(Fragment.from(schema.nodes.paragraph.create()));
    const tr = closeHistory(current.state.tr);
    if (current.hasFocus() && current.state.selection.empty) {
      tr.replaceSelection(new Slice(content, 0, 0));
      // A block insertion splits the paragraph's old tail off after the new reply line.
      const end = tr.selection.$from;
      if (end.depth === 1 && end.parentOffset === 0 && end.parent.content.size) {
        const before = end.before();
        const reply = tr.doc.resolve(before).nodeBefore;
        if (reply?.type === schema.nodes.paragraph && !reply.content.size)
          tr.setSelection(TextSelection.create(tr.doc, before - 1));
      }
    } else {
      // Append outside a final quote/list, reusing an empty reply paragraph.
      const last = doc.lastChild;
      const from =
        last?.type === schema.nodes.paragraph && !last.content.size
          ? doc.content.size - last.nodeSize
          : doc.content.size;
      tr.replaceWith(from, doc.content.size, content);
      tr.setSelection(TextSelection.near(tr.doc.resolve(from + content.size), -1));
    }
    current.dispatch(tr.scrollIntoView());
    current.focus();
  });
}
