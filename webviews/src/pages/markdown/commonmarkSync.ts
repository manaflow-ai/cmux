// Milkdown's commonmark preset keeps heading ids and ordered list labels in sync with a walk of
// the whole document on each edit (syncHeadingIdPlugin, syncListOrderPlugin): a keystroke in a
// 10,000-line file visited every node twice. These do the same work over only the top-level blocks
// the edit changed (and, for ids, the headings sharing an id with one it changed), when the
// document before it was in sync; otherwise they check all of it, as Milkdown's do.
//
// On an @milkdown upgrade (written against @milkdown/kit and @milkdown/preset-commonmark 7.22.2),
// re-check against preset-commonmark's src/plugin/sync-heading-id-plugin.ts (`updateId`: which
// headings get an id, the `-#n` suffix, the `view.composing` skip, the `doc.eq` early return) and
// src/plugin/sync-list-order-plugin.ts (`syncOrderLabel`: the skip on `addToHistory: false` or a
// non-generic transaction, the bullet-to-ordered conversion, `label` and `listType`), that
// src/composed/plugins.ts still holds both (`boundedCommonmark` filters them out by identity), and
// that `headingIdGenerator` is still the ctx key for ids. markdown-commonmark-sync.test.ts runs
// Milkdown's plugins beside these over the same edits. Two deliberate divergences: `milkdownIds`
// for ids that are Object.prototype keys, and `listOrderPlugin` for an ordered list's bullet item
// whose label is already right; see each.
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
import { BlockIndex, changedSpan, headingsIn, type Entry } from "./headingIndex";

/** Documents whose heading ids are Milkdown's: an edit of one needs only the ids it touched checked. */
const headingIdsSynced = new WeakSet<ProseNode>();
const headingIdKey = new PluginKey("cmuxMarkdownHeadingId");

/**
 * Milkdown's ids for headings with these ids from their text, in order (its `updateId`): the first
 * of an id keeps it, the rest get `-#2` and on. A deliberate divergence: Milkdown counts on a plain
 * object, so a heading whose id is an Object.prototype key ("constructor", "__proto__") counts as
 * a repeat from the first and gets `constructor-#function Object() {…}1`; a Map gives it its own.
 */
function milkdownIds(bases: readonly string[]): string[] {
  const seen = new Map<string, number>();
  return bases.map((base) => {
    const count = (seen.get(base) ?? 0) + 1;
    seen.set(base, count);
    return count === 1 ? base : `${base}-#${count}`;
  });
}

/**
 * syncHeadingIdPlugin over an index of the headings (headingIndex.ts): an edit of a document in
 * sync checks only the headings whose id from their text it added or removed, and the others with
 * that id (their `-#n` follows the count before them). An id depends only on the headings with the
 * same one, so the rest still hold.
 */
const headingIdPlugin = $prose((ctx) => {
  const headingType = () => headingSchema.type(ctx);
  const index = new BlockIndex<ProseNode>({
    // A block's ids from text are read once: a headingIdGenerator set after the editor starts would
    // not reach the blocks read before it (cmux sets none).
    find: (block) => {
      const getId = ctx.get(headingIdGenerator.key);
      return headingsIn(
        block,
        (node) => node.type === headingType(),
        (heading) => (heading.textContent.trim().length ? getId(heading) : null),
      );
    },
    ids: milkdownIds,
  });
  /** Sets each of `headings` whose id is not the one it gets; the document is then in sync. */
  const sync = (view: EditorView, headings: readonly Entry<ProseNode>[]) => {
    const tr = view.state.tr.setMeta("addToHistory", false);
    let found = false;
    for (const heading of headings) {
      if (heading.value.attrs.id === heading.id) continue;
      found = true;
      tr.setMeta(headingIdKey, true).setNodeMarkup(heading.pos, undefined, { ...heading.value.attrs, id: heading.id });
    }
    if (!found) {
      headingIdsSynced.add(view.state.doc);
      return;
    }
    headingIdsSynced.add(tr.doc);
    view.dispatch(tr);
  };
  return new Plugin({
    key: headingIdKey,
    view: (view) => {
      if (!view.composing) sync(view, index.entries(view.state.doc));
      return {
        update: (view, prevState) => {
          const doc = view.state.doc;
          // Carried on each update, so the next edit reads only its own blocks.
          const change = index.step(prevState.doc, doc);
          if (headingIdsSynced.has(doc) || view.composing) return;
          if (!headingIdsSynced.has(prevState.doc)) {
            // Milkdown's: a document out of sync is checked whole, unless the update changed nothing.
            if (!doc.eq(prevState.doc)) sync(view, index.entries(doc));
            return;
          }
          sync(view, change ? change.regrouped : index.entries(doc));
        },
      };
    },
  });
});

/** Documents whose ordered list labels are Milkdown's (or that a list sync left as they were). */
const listOrderSynced = new WeakSet<ProseNode>();

/**
 * syncListOrderPlugin, walking only the changed blocks of a document that was in sync. One
 * deliberate divergence: an ordered list's item with listType "bullet" and the right label is made
 * "ordered" (Milkdown's label check overwrites the listType change and leaves it a bullet).
 */
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
            // A deliberate divergence: Milkdown's `changed = handleNodeItem(...)` drops the listType
            // change, so an item with listType "bullet" and the right label stayed a bullet.
            if (parent?.maybeChild(0)) changed = handleNodeItem(attrs, index, parent?.attrs.order ?? 1) || changed;
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
