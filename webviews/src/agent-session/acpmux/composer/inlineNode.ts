// An attachment placed in the prompt's text (Leo, 2026-10-25: "the actual input, as a default, I
// don't think it's gonna be worse to put the things inline, like how iMessage on Mac does it"): one
// ProseMirror atom per attachment, tied to it by the attachment's id, never by its place among the
// others. The draft writes it as the id between two marks (attachments.ts inlineToken), so a draft
// read back, a value set from outside and undo all bring back the same attachment, and a copy pasted
// in the same prompt brings a copy of it (a new id naming the one it was copied from,
// attachments.ts inlineCopyId). The node draws nothing itself: the composer draws each
// attachment's chip into the node's element (composer/inlineAttachments.tsx), which `InlineViews`
// hands it.
import { closeHistory } from "@milkdown/kit/prose/history";
import { Fragment, type Node as ProseNode, type Slice } from "@milkdown/kit/prose/model";
import { type EditorState, Plugin, TextSelection, type Transaction } from "@milkdown/kit/prose/state";
import type { EditorView, NodeView } from "@milkdown/kit/prose/view";
import { $node, $prose } from "@milkdown/kit/utils";
import { INLINE_ATTACHMENT_MARK, inlineCopyId, inlineToken, inlineTokenSpans } from "../attachments";

export const INLINE_NODE = "inline_attachment";

/// Where the composer draws each placed attachment: the element of its node, by id.
export type InlineViews = { add(id: string, dom: HTMLElement): void; remove(id: string, dom: HTMLElement): void };

/// Whether `id` is one of the composer's attachments, which the text's tokens are read against
/// (attachments.ts inlineTokenSpans): the person's U+FFFC just before a word and an attachment's
/// token stays their text. Every id is taken for one where the composer does not say.
export type InlineKnown = (id: string) => boolean;

export const inlineAttachmentNode = $node(INLINE_NODE, () => ({
  group: "inline",
  inline: true,
  atom: true,
  selectable: true,
  // ProseMirror moves this atom with its text; an internal drag carries no external files.
  draggable: true,
  attrs: { id: { default: "" } },
  parseDOM: [{ tag: "span[data-inline-attachment]", getAttrs: (dom) => ({ id: dom.dataset.inlineAttachment ?? "" }) }],
  toDOM: (node) => ["span", { "data-inline-attachment": node.attrs.id as string }],
  // Read from the text's tokens after parsing (`placeTokensIn`): markdown has no syntax for it.
  parseMarkdown: { match: () => false, runner: () => {} },
  toMarkdown: {
    match: (node) => node.type.name === INLINE_NODE,
    runner: (state, node) => {
      state.addNode("html", undefined, inlineToken(node.attrs.id as string));
    },
  },
}));

const idOf = (node: ProseNode) => node.attrs.id as string;

/// Whether `content` holds a node that `test` says yes to.
function holds(content: Fragment, test: (node: ProseNode) => boolean): boolean {
  let found = false;
  content.descendants((node) => {
    if (found) return false;
    found = test(node);
    return !found;
  });
  return found;
}

/// Whether a paste carries a placed attachment's own node: a copy of the prompt's text with one in
/// it. A U+FFFC in other copied text (a page's bold run) is only text, and pastes as text.
export const sliceHoldsInline = (slice: Slice) => holds(slice.content, (node) => node.type.name === INLINE_NODE);

/// Each placed attachment's node in `doc`, in order.
function inlineNodes(doc: ProseNode): { id: string; pos: number }[] {
  const found: { id: string; pos: number }[] = [];
  doc.descendants((node, pos) => {
    if (node.type.name === INLINE_NODE) found.push({ id: idOf(node), pos });
    return node.isTextblock ? node.type.spec.code !== true : true;
  });
  return found;
}

/// `tr` with each token in its document's text turned into its node, read against `known`. A token
/// of an id the composer does not have is a node too, drawing nothing: the prompt sends it as
/// nothing (attachments.ts placeInline). Only a value set from the composer's side (the draft, a
/// value from outside, MarkdownField.tsx setDocument) is read so: token text that was typed or
/// pasted stays text, and undo and redo bring back nodes, never tokens.
export function placeTokensIn(tr: Transaction, known: InlineKnown): Transaction {
  const type = tr.doc.type.schema.nodes[INLINE_NODE];
  if (!type) return tr;
  const tokens: { from: number; to: number; id: string }[] = [];
  tr.doc.descendants((node, pos, parent) => {
    if (!node.isText || !node.text!.includes(INLINE_ATTACHMENT_MARK) || parent?.type.spec.code) return;
    for (const span of inlineTokenSpans(node.text!, known))
      tokens.push({ from: pos + span.from, to: pos + span.to, id: span.id });
  });
  for (const token of tokens.reverse()) tr.replaceWith(token.from, token.to, type.create({ id: token.id }));
  return tr;
}

/// After an edit that brought in placed attachments' nodes (a value set from outside, a paste of the
/// prompt's own copy, an undo): a second node of an id already in the prompt (a copy pasted beside
/// its original) gets a copy's id, the original keeping its own.
function normalize(transactions: readonly Transaction[], previous: EditorState, state: EditorState) {
  const brought = transactions.some((tr) =>
    tr.steps.some((step) => {
      const slice = (step as { slice?: Slice }).slice;
      return slice ? sliceHoldsInline(slice) : false;
    }),
  );
  if (!brought) return null;
  const tr = state.tr;
  // Where each id held before the edit is now: that node keeps it.
  const kept = new Map<string, number>();
  const mapped = (pos: number) => {
    let at = pos;
    for (const each of transactions) at = each.mapping.map(at);
    return tr.mapping.map(at);
  };
  for (const { id, pos } of inlineNodes(previous.doc)) if (!kept.has(id)) kept.set(id, mapped(pos));
  const nodes = inlineNodes(tr.doc);
  const owner = new Map<string, number>();
  for (const { id, pos } of nodes) if (kept.get(id) === pos) owner.set(id, pos);
  for (const { id, pos } of nodes) {
    // An id new to the prompt, or one whose original went: its first node keeps it.
    if (!owner.has(id)) owner.set(id, pos);
    if (owner.get(id) !== pos) tr.setNodeMarkup(pos, undefined, { id: inlineCopyId(id) });
  }
  return tr.docChanged ? tr : null;
}

function nodeView(node: ProseNode, view: EditorView, views: InlineViews): NodeView {
  const id = idOf(node);
  const dom = view.dom.ownerDocument.createElement("span");
  dom.className = "acpmux-md-inline";
  dom.contentEditable = "false";
  dom.dataset.inlineAttachment = id;
  views.add(id, dom);
  return {
    dom,
    // Another id is another attachment: its own element.
    update: (next) => next.type === node.type && idOf(next) === id,
    // The chip drawn inside is the composer's.
    ignoreMutation: () => true,
    // Its buttons (×, Retry, open) are the chip's; a press elsewhere on it selects the node.
    stopEvent: (event) =>
      event.target instanceof Element && event.target !== dom && Boolean(event.target.closest("button")),
    destroy: () => views.remove(id, dom),
  };
}

export function inlinePlugin(views: InlineViews) {
  return $prose(
    () =>
      new Plugin({
        props: {
          nodeViews: { [INLINE_NODE]: (node, view) => nodeView(node, view, views) },
          handleKeyDown: (view, event) => {
            if (event.isComposing || event.metaKey || event.ctrlKey || event.altKey || event.shiftKey) return false;
            const { selection } = view.state;
            if (!selection.empty || !(selection instanceof TextSelection)) return false;
            const backward = event.key === "Backspace";
            if (!backward && event.key !== "Delete") return false;
            const adjacent = backward ? selection.$from.nodeBefore : selection.$from.nodeAfter;
            if (adjacent?.type.name !== INLINE_NODE) return false;
            const from = selection.from - (backward ? 1 : 0);
            view.dispatch(
              closeHistory(view.state.tr)
                .delete(from, from + 1)
                .scrollIntoView(),
            );
            return true;
          },
        },
        appendTransaction: (transactions, previous, state) => normalize(transactions, previous, state),
      }),
  );
}

/// Places attachments `ids` at the selection, the caret after them; false where they cannot go (a
/// code block) or the editor has no such node.
export function insertInline(view: EditorView, ids: readonly string[]): boolean {
  const type = view.state.schema.nodes[INLINE_NODE];
  if (!type || ids.length === 0) return false;
  const { $from, $to, from, to } = view.state.selection;
  if (!$from.parent.inlineContent || $from.parent.type.spec.code || $from.parent !== $to.parent) return false;
  const nodes = Fragment.from(ids.map((id) => type.create({ id })));
  if (!$from.parent.canReplace($from.index(), $to.index(), nodes)) return false;
  const tr = view.state.tr.replaceWith(from, to, nodes);
  tr.setSelection(TextSelection.near(tr.doc.resolve(tr.mapping.map(to))));
  view.dispatch(tr.scrollIntoView());
  return true;
}

/// Takes attachment `id`'s node out of the prompt, as an undoable edit.
export function removeInline(view: EditorView, id: string) {
  const found = inlineNodes(view.state.doc).filter((node) => node.id === id);
  if (!found.length) return;
  const tr = view.state.tr;
  for (const { pos } of found.reverse()) tr.delete(pos, pos + 1);
  view.dispatch(tr);
}

/// Puts the placed attachments in `ids`' order, each node keeping its place in the text: the nodes
/// trade attachments (the strip's drag, composer/stripReorder.ts).
export function orderInline(view: EditorView, ids: readonly string[]) {
  const wanted = new Set(ids);
  const nodes = inlineNodes(view.state.doc).filter((node) => wanted.has(node.id));
  const order = ids.filter((id) => nodes.some((node) => node.id === id));
  if (nodes.length !== order.length || nodes.every((node, index) => node.id === order[index])) return;
  const tr = view.state.tr;
  nodes.forEach(({ pos }, index) => tr.setNodeMarkup(pos, undefined, { id: order[index] }));
  view.dispatch(tr);
}
