// An attachment placed in the prompt's text (Leo, 2026-10-25: "the actual input, as a default, I
// don't think it's gonna be worse to put the things inline, like how iMessage on Mac does it"): one
// ProseMirror atom per attachment, tied to it by the attachment's id, never by its place among the
// others. The draft writes it as the id between two marks (attachments.ts inlineToken), so a draft
// read back, a value set from outside and undo all bring back the same attachment, and a copy pasted
// in the same prompt brings a copy of it (a new id with the copied one's root, `root~copy`). The
// node draws nothing itself: the composer draws each attachment's chip into the node's element
// (composer/inlineAttachments.tsx), which `InlineViews` hands it.
import { Fragment, type Node as ProseNode, type Slice } from "@milkdown/kit/prose/model";
import { type EditorState, Plugin, TextSelection, type Transaction } from "@milkdown/kit/prose/state";
import type { EditorView, NodeView } from "@milkdown/kit/prose/view";
import { $node, $prose } from "@milkdown/kit/utils";
import { INLINE_ATTACHMENT_MARK, INLINE_TOKEN, inlineToken } from "../attachments";

export const INLINE_NODE = "inline_attachment";

/// Where the composer draws each placed attachment: the element of its node, by id.
export type InlineViews = { add(id: string, dom: HTMLElement): void; remove(id: string, dom: HTMLElement): void };

export const inlineAttachmentNode = $node(INLINE_NODE, () => ({
  group: "inline",
  inline: true,
  atom: true,
  selectable: true,
  // A drag would carry it as HTML into the page's file drop; it moves by its strip chip instead.
  draggable: false,
  attrs: { id: { default: "" } },
  parseDOM: [{ tag: "span[data-inline-attachment]", getAttrs: (dom) => ({ id: dom.dataset.inlineAttachment ?? "" }) }],
  toDOM: (node) => ["span", { "data-inline-attachment": node.attrs.id as string }],
  // Read from the text's tokens after parsing (`inlinePlugin`): markdown has no syntax for it.
  parseMarkdown: { match: () => false, runner: () => {} },
  toMarkdown: {
    match: (node) => node.type.name === INLINE_NODE,
    runner: (state, node) => {
      state.addNode("html", undefined, inlineToken(node.attrs.id as string));
    },
  },
}));

const idOf = (node: ProseNode) => node.attrs.id as string;

/// Whether `content` holds a placed attachment, as a node or as its token's text.
function holdsInline(content: Fragment): boolean {
  let found = false;
  content.descendants((node) => {
    if (found) return false;
    if (node.type.name === INLINE_NODE || (node.isText && node.text!.includes(INLINE_ATTACHMENT_MARK))) found = true;
    return !found;
  });
  return found;
}

export const sliceHoldsInline = (slice: Slice) => holdsInline(slice.content);

/// A copy's id: the copied one's root with a suffix of its own.
const copyId = (id: string) => `${id.split("~")[0]}~${crypto.randomUUID().slice(0, 8)}`;

/// Each placed attachment's node in `doc`, in order.
function inlineNodes(doc: ProseNode): { id: string; pos: number }[] {
  const found: { id: string; pos: number }[] = [];
  doc.descendants((node, pos) => {
    if (node.type.name === INLINE_NODE) found.push({ id: idOf(node), pos });
    return node.isTextblock ? node.type.spec.code !== true : true;
  });
  return found;
}

/// A transaction turning each token in `state`'s text into its node; undefined where the editor has
/// no such node.
function tokensToNodes(state: EditorState): Transaction | undefined {
  const type = state.schema.nodes[INLINE_NODE];
  if (!type) return undefined;
  const tr = state.tr;
  const tokens: { from: number; to: number; id: string }[] = [];
  state.doc.descendants((node, pos, parent) => {
    if (!node.isText || !node.text!.includes(INLINE_ATTACHMENT_MARK) || parent?.type.spec.code) return;
    for (const match of node.text!.matchAll(INLINE_TOKEN))
      tokens.push({ from: pos + match.index, to: pos + match.index + match[0].length, id: match[1]! });
  });
  for (const token of tokens.reverse()) tr.replaceWith(token.from, token.to, type.create({ id: token.id }));
  return tr;
}

/// After an edit that brought in placed attachments (a value set from outside, a paste, an undo):
/// each token in the text becomes its node, and a second node of an id already in the prompt (a
/// copy pasted beside its original) gets a copy's id, the original keeping its own.
function normalize(transactions: readonly Transaction[], previous: EditorState, state: EditorState) {
  const brought = transactions.some((tr) =>
    tr.steps.some((step) => {
      const slice = (step as { slice?: Slice }).slice;
      return slice ? sliceHoldsInline(slice) : false;
    }),
  );
  if (!brought) return null;
  const tr = tokensToNodes(state);
  if (!tr) return null;
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
    if (owner.get(id) !== pos) tr.setNodeMarkup(pos, undefined, { id: copyId(id) });
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
        props: { nodeViews: { [INLINE_NODE]: (node, view) => nodeView(node, view, views) } },
        appendTransaction: (transactions, previous, state) => normalize(transactions, previous, state),
        // The editor's first content (a draft read back: a chat reopened, a relaunch) comes in with no
        // transaction: its tokens become their nodes once the view is up, outside undo's history.
        view: (editorView) => {
          queueMicrotask(() => {
            if (editorView.isDestroyed) return;
            const tr = tokensToNodes(editorView.state);
            if (tr?.docChanged) editorView.dispatch(tr.setMeta("addToHistory", false));
          });
          return {};
        },
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
