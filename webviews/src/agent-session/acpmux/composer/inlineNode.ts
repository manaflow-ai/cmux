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
import { Fragment, type Node as ProseNode, Slice } from "@milkdown/kit/prose/model";
import { type EditorState, Plugin, Selection, TextSelection, type Transaction } from "@milkdown/kit/prose/state";
import { Decoration, DecorationSet, type EditorView, type NodeView } from "@milkdown/kit/prose/view";
import { $node, $prose } from "@milkdown/kit/utils";
import {
  escapeTextMarks,
  INLINE_ATTACHMENT_MARK,
  inlineCopyId,
  inlineToken,
  inlineTokenSpans,
  unescapeTextMarks,
} from "../attachments";

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

/// The ids of the attachments placed in `doc`, its own nodes only (never text shaped like a token),
/// in order, each once.
export const inlineIds = (doc: ProseNode) => [...new Set(inlineNodes(doc).map((node) => node.id))];

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
  // The person's own U+FFFC, which the draft writes escaped (`withTextMarksEscaped`), is theirs again.
  const escaped: { from: number; node: ProseNode }[] = [];
  tr.doc.descendants((node, pos) => {
    if (!node.isText) return;
    const text = unescapeTextMarks(node.text!);
    if (text !== node.text) escaped.push({ from: pos, node });
  });
  for (const { from, node } of escaped.reverse())
    tr.replaceWith(from, from + node.nodeSize, node.type.schema.text(unescapeTextMarks(node.text!), node.marks));
  return tr;
}

/// `doc` as the draft writes it: the person's own U+FFFC in a run of text shaped like a token
/// escaped (attachments.ts escapeTextMarks), so only the nodes write tokens. `doc` itself when
/// nothing needs it.
export function withTextMarksEscaped(doc: ProseNode): ProseNode {
  const runs: { from: number; to: number; node: ProseNode }[] = [];
  doc.descendants((node, pos) => {
    if (!node.isText || !node.text!.includes(INLINE_ATTACHMENT_MARK)) return;
    const text = escapeTextMarks(node.text!);
    if (text !== node.text)
      runs.push({ from: pos, to: pos + node.nodeSize, node: node.type.schema.text(text, node.marks) });
  });
  let escaped = doc;
  for (const { from, to, node } of runs.reverse())
    escaped = escaped.replace(from, to, new Slice(Fragment.from(node), 0, 0));
  return escaped;
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

/// A piece of a selection as a copy carries it (composer/composerCopy.ts): a run of its text, as the
/// field copies text (a line or block break a newline), or a placed attachment, by id.
export type SelectionPart = { text: string } | { id: string };

/// Stands in for each placed attachment while the selection's text is read: a private-use character,
/// never in a node's text the field's own copy writes (`selectionParts`).
const PART_MARK = "\uE000";

/// The selection of `state` as its runs of text and its placed attachments, in order. Text runs
/// read as the field's own copy does (MarkdownField `copiedText`).
export function selectionParts(state: EditorState): SelectionPart[] {
  const { from, to } = state.selection;
  const ids: string[] = [];
  state.doc.nodesBetween(from, to, (node) => {
    if (node.type.name === INLINE_NODE) ids.push(idOf(node));
  });
  const text = state.doc.textBetween(from, to, "\n", (leaf) =>
    leaf.type.name === INLINE_NODE ? PART_MARK : (leaf.type.spec.leafText?.(leaf) ?? ""),
  );
  const parts: SelectionPart[] = [];
  text.split(PART_MARK).forEach((run, index) => {
    const id = index > 0 ? ids[index - 1] : undefined;
    if (id !== undefined) parts.push({ id });
    if (run) parts.push({ text: run });
  });
  return parts;
}

/// Whether the selection of `state` holds the whole draft: Select All, or a drag from its start to
/// its end.
export function wholeSelected(state: EditorState): boolean {
  const { selection, doc } = state;
  if (selection.empty) return false;
  return selection.from <= Selection.atStart(doc).from && selection.to >= Selection.atEnd(doc).to;
}

/// The placed attachments inside a selection wear the selection's tint, as its text does: a chip is
/// not text, so the browser's own highlight passes over it (Leo, 2026-11-01: "select all in composer
/// which also selects all the attachments").
function selectedDecorations(state: EditorState): DecorationSet | null {
  const { selection, doc } = state;
  if (selection.empty) return null;
  const marks: Decoration[] = [];
  doc.nodesBetween(selection.from, selection.to, (node, pos) => {
    if (node.type.name === INLINE_NODE)
      marks.push(Decoration.node(pos, pos + node.nodeSize, { class: "acpmux-md-inline-selected" }));
  });
  return marks.length ? DecorationSet.create(doc, marks) : null;
}

export function inlinePlugin(views: InlineViews) {
  return $prose(
    () =>
      new Plugin({
        props: {
          decorations: selectedDecorations,
          nodeViews: { [INLINE_NODE]: (node, view) => nodeView(node, view, views) },
          handleKeyDown: (view, event) => {
            if (event.isComposing || event.metaKey || event.ctrlKey || event.altKey || event.shiftKey) return false;
            const { selection } = view.state;
            if (!selection.empty || !(selection instanceof TextSelection)) return false;
            // Left and Right step over a placed attachment as over one character, never selecting it
            // (Leo, 2026-11-01: "i dont want left arrow to be selecting them??? just jump over them
            // treat them like it's one character"). ProseMirror's own Shift+arrow already extends
            // over it as one unit.
            if (event.key === "ArrowLeft" || event.key === "ArrowRight") {
              const left = event.key === "ArrowLeft";
              const { $head } = selection;
              const adjacent = $head.textOffset ? null : left ? $head.nodeBefore : $head.nodeAfter;
              if (adjacent?.type.name !== INLINE_NODE) return false;
              const to = $head.pos + (left ? -adjacent.nodeSize : adjacent.nodeSize);
              view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, to)).scrollIntoView());
              return true;
            }
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
export function removeInline(view: EditorView, id: string, caret = false) {
  const found = inlineNodes(view.state.doc).filter((node) => node.id === id);
  if (!found.length) return;
  // `caret`: what goes in next (a pasted chip's text) takes the attachment's place, not the caret's,
  // and the two are one undo step of their own, as a Backspace over the node is: an undo brings the
  // chip back, never the typing before it.
  const tr = caret ? closeHistory(view.state.tr) : view.state.tr;
  const first = found[0]!.pos;
  for (const { pos } of found.reverse()) tr.delete(pos, pos + 1);
  if (caret) tr.setSelection(TextSelection.create(tr.doc, first));
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
