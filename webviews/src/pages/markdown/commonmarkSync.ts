// Milkdown's commonmark preset keeps heading ids and ordered list labels in sync with a walk of
// the whole document on each edit (syncHeadingIdPlugin, syncListOrderPlugin): a keystroke in a
// 10,000-line file visited every node twice. These do the same work over only the top-level blocks
// the edit changed, when the document before it was in sync; otherwise they walk all of it, as
// Milkdown's do.
//
// On an @milkdown upgrade (written against @milkdown/kit and @milkdown/preset-commonmark 7.22.2),
// re-check against preset-commonmark's src/plugin/sync-heading-id-plugin.ts (`updateId`: which
// headings get an id, the `-#n` suffix, the `view.composing` skip, the `doc.eq` early return) and
// src/plugin/sync-list-order-plugin.ts (`syncOrderLabel`: the skip on `addToHistory: false` or a
// non-generic transaction, the bullet-to-ordered conversion, `label` and `listType`), that
// src/composed/plugins.ts still holds both (`boundedCommonmark` filters them out by identity), and
// that `headingIdGenerator` is still the ctx key for ids. markdown-commonmark-sync.test.ts runs
// Milkdown's plugins beside these over the same edits.
import type { Node as ProseNode } from "@milkdown/kit/prose/model";
import { Plugin, PluginKey, type Transaction } from "@milkdown/kit/prose/state";
import type { EditorView } from "@milkdown/kit/prose/view";
import {
  bulletListSchema,
  commonmark,
  headingIdGenerator,
  headingSchema,
  listItemSchema,
  orderedListSchema,
  syncHeadingIdPlugin,
  syncListOrderPlugin,
} from "@milkdown/kit/preset/commonmark";
import { $prose } from "@milkdown/kit/utils";
import { blocksAround, type BlockRange } from "./redecorate";

/** The whole top-level blocks that differ between `a` and `b` (in each), or null when they are equal. */
function changedSpan(a: ProseNode, b: ProseNode): { before: BlockRange; after: BlockRange } | null {
  const start = a.content.findDiffStart(b.content);
  if (start === null) return null;
  let { a: endA, b: endB } = a.content.findDiffEnd(b.content)!;
  // A change in repeated text matches its end before its start (prosemirror-view's readDOMChange).
  const adjust = Math.max(0, start - Math.min(endA, endB));
  endA += adjust;
  endB += adjust;
  return { before: blocksAround(a, start, endA), after: blocksAround(b, start, endB) };
}

/** Documents whose heading ids are Milkdown's: an edit of one needs only its changed blocks checked. */
const headingIdsSynced = new WeakSet<ProseNode>();
const headingIdKey = new PluginKey("cmuxMarkdownHeadingId");

/** syncHeadingIdPlugin, checking only the changed blocks of a document that was in sync. */
const headingIdPlugin = $prose((ctx) => {
  const headingType = () => headingSchema.type(ctx);
  /** Each heading with text in `from`..`to`: its id from its text, and the id it has. */
  const headings = (doc: ProseNode, { from, to }: BlockRange) => {
    const getId = ctx.get(headingIdGenerator.key);
    const out: Array<{ base: string; id: unknown }> = [];
    doc.nodesBetween(from, to, (node) => {
      if (node.type !== headingType()) return !node.isTextblock;
      if (node.textContent.trim().length) out.push({ base: getId(node), id: node.attrs.id });
      return false;
    });
    return out;
  };
  /** The same headings, by id from their text, with the ids they had: the ids of the rest still hold. */
  const kept = (before: ProseNode, after: ProseNode): boolean => {
    const span = changedSpan(before, after);
    if (!span) return true;
    const old = headings(before, span.before);
    const now = headings(after, span.after);
    return (
      old.length === now.length &&
      old.every((heading, at) => heading.base === now[at]!.base && heading.id === now[at]!.id)
    );
  };
  // Milkdown's own: every heading with text gets its id, `-#2` and on for a repeat.
  const updateId = (view: EditorView) => {
    if (view.composing) return;
    const getId = ctx.get(headingIdGenerator.key);
    const tr = view.state.tr.setMeta("addToHistory", false);
    let found = false;
    const seen: Record<string, number> = {};
    view.state.doc.descendants((node, pos) => {
      if (node.type !== headingType() || node.textContent.trim().length === 0) return;
      let id = getId(node);
      if (seen[id]) {
        seen[id] += 1;
        id += `-#${seen[id]}`;
      } else seen[id] = 1;
      if (node.attrs.id !== id) {
        found = true;
        tr.setMeta(headingIdKey, true).setNodeMarkup(pos, undefined, { ...node.attrs, id });
      }
    });
    if (found) view.dispatch(tr);
    else headingIdsSynced.add(view.state.doc);
  };
  return new Plugin({
    key: headingIdKey,
    view: (view) => {
      updateId(view);
      return {
        update: (view, prevState) => {
          const doc = view.state.doc;
          if (headingIdsSynced.has(doc)) return;
          if (!view.composing && headingIdsSynced.has(prevState.doc) && kept(prevState.doc, doc)) {
            headingIdsSynced.add(doc);
            return;
          }
          if (!doc.eq(prevState.doc)) updateId(view);
        },
      };
    },
  });
});

/** Documents whose ordered list labels are Milkdown's (or that a list sync left as they were). */
const listOrderSynced = new WeakSet<ProseNode>();

/** syncListOrderPlugin, walking only the changed blocks of a document that was in sync. */
const listOrderPlugin = $prose(
  (ctx) =>
    new Plugin({
      key: new PluginKey("cmuxMarkdownListOrder"),
      appendTransaction: (transactions: readonly Transaction[], oldState, newState) => {
        if (!newState.selection || transactions.some((tr) => tr.getMeta("addToHistory") === false || !tr.isGeneric)) {
          // A heading id sync changes no list: the document stays in sync.
          if (
            listOrderSynced.has(oldState.doc) &&
            transactions.every((tr) => !tr.docChanged || tr.getMeta(headingIdKey))
          )
            listOrderSynced.add(newState.doc);
          return null;
        }
        const orderedListType = orderedListSchema.type(ctx);
        const bulletListType = bulletListSchema.type(ctx);
        const listItemType = listItemSchema.type(ctx);
        // Milkdown's own: a bullet list of ordered items becomes an ordered list, each item labelled.
        const handleNodeItem = (attrs: Record<string, unknown>, index: number, order = 1) => {
          const expectedLabel = `${index + order}.`;
          if (attrs.label === expectedLabel) return false;
          attrs.label = expectedLabel;
          return true;
        };
        let tr = newState.tr;
        let needDispatch = false;
        let converted = false;
        const visit = (node: ProseNode, pos: number, parent: ProseNode | null, index: number) => {
          if (node.type === bulletListType) {
            const base = node.maybeChild(0);
            if (base?.type === listItemType && base.attrs.listType === "ordered") {
              needDispatch = true;
              converted = true;
              tr.setNodeMarkup(pos, orderedListType, { spread: true });
              node.descendants((child, pos, _parent, index) => {
                if (child.type === listItemType) {
                  const attrs = { ...child.attrs };
                  if (handleNodeItem(attrs, index)) tr = tr.setNodeMarkup(pos, undefined, attrs);
                }
                return false;
              });
            }
          } else if (node.type === listItemType && parent?.type === orderedListType) {
            const attrs = { ...node.attrs };
            let changed = false;
            if (attrs.listType !== "ordered") {
              attrs.listType = "ordered";
              changed = true;
            }
            if (parent?.maybeChild(0)) changed = handleNodeItem(attrs, index, parent?.attrs.order ?? 1);
            if (changed) {
              tr = tr.setNodeMarkup(pos, undefined, attrs);
              needDispatch = true;
            }
          }
        };
        // A list's labels are its own: the blocks the edit left are as they were, in sync.
        if (listOrderSynced.has(oldState.doc)) {
          const span = changedSpan(oldState.doc, newState.doc);
          if (span) newState.doc.nodesBetween(span.after.from, span.after.to, visit);
        } else newState.doc.descendants(visit);
        if (!needDispatch) {
          listOrderSynced.add(newState.doc);
          return null;
        }
        // A bullet list made ordered keeps its items' labels until the next walk (Milkdown's walk of
        // its items gives positions in the list as the document's): that next walk is whole, as Milkdown's.
        if (!converted) listOrderSynced.add(tr.doc);
        return tr.setMeta("addToHistory", false);
      },
    }),
);

/** The commonmark preset with its heading id and list order syncs bounded by the edit. */
export const boundedCommonmark = [
  ...commonmark.filter((plugin) => plugin !== syncHeadingIdPlugin && plugin !== syncListOrderPlugin),
  headingIdPlugin,
  listOrderPlugin,
];
