// Formatting commands for the Markdown field (MarkdownField.tsx), for a surface that shows a
// format toolbar (the channels Home composer). Each kind is a real Markdown construct, so the sent
// text carries it (`**bold**`, `~~strike~~`, a list, a fence); there is no underline, because
// Markdown cannot keep one. A command toggles: applied again where it is active, it comes off.
import type { Editor } from "@milkdown/kit/core";
import {
  createCodeBlockCommand,
  toggleEmphasisCommand,
  toggleInlineCodeCommand,
  toggleStrongCommand,
  turnIntoTextCommand,
  wrapInBlockquoteCommand,
  wrapInBulletListCommand,
  wrapInOrderedListCommand,
} from "@milkdown/kit/preset/commonmark";
import { toggleStrikethroughCommand } from "@milkdown/kit/preset/gfm";
import type { MarkType } from "@milkdown/kit/prose/model";
import type { EditorState } from "@milkdown/kit/prose/state";
import { liftTarget } from "@milkdown/kit/prose/transform";
import { liftListItem } from "@milkdown/kit/prose/schema-list";
import type { EditorView } from "@milkdown/kit/prose/view";
import { callCommand } from "@milkdown/kit/utils";

export type MarkdownFormat =
  | "bold"
  | "italic"
  | "strike"
  | "link"
  | "orderedList"
  | "bulletList"
  | "quote"
  | "code"
  | "codeBlock";

const MARKS: Partial<Record<MarkdownFormat, string>> = {
  bold: "strong",
  italic: "emphasis",
  strike: "strike_through",
  code: "inlineCode",
  link: "link",
};

const NODES: Partial<Record<MarkdownFormat, string>> = {
  orderedList: "ordered_list",
  bulletList: "bullet_list",
  quote: "blockquote",
  codeBlock: "code_block",
};

/** The formats active at the selection (marks over the whole selection, blocks around its start). */
export function activeFormats(state: EditorState): Set<MarkdownFormat> {
  const active = new Set<MarkdownFormat>();
  const { from, to, empty, $from } = state.selection;
  for (const [format, name] of Object.entries(MARKS) as [MarkdownFormat, string][]) {
    const type = state.schema.marks[name];
    if (!type) continue;
    const on = empty
      ? (state.storedMarks ?? $from.marks()).some((mark) => mark.type === type)
      : state.doc.rangeHasMark(from, to, type);
    if (on) active.add(format);
  }
  for (let depth = $from.depth; depth > 0; depth -= 1) {
    const name = $from.node(depth).type.name;
    for (const [format, node] of Object.entries(NODES) as [MarkdownFormat, string][])
      if (node === name) active.add(format);
  }
  return active;
}

/** Applies or removes one format at the selection. A link takes `href`; with no selection the
 * link's address becomes its text. */
export function applyFormat(editor: Editor, view: EditorView, format: MarkdownFormat, href?: string): void {
  const on = activeFormats(view.state).has(format);
  switch (format) {
    case "bold":
      editor.action(callCommand(toggleStrongCommand.key));
      break;
    case "italic":
      editor.action(callCommand(toggleEmphasisCommand.key));
      break;
    case "strike":
      editor.action(callCommand(toggleStrikethroughCommand.key));
      break;
    case "code":
      editor.action(callCommand(toggleInlineCodeCommand.key));
      break;
    case "link":
      applyLink(view, on, href);
      break;
    case "orderedList":
    case "bulletList": {
      const item = view.state.schema.nodes.list_item;
      const other = format === "orderedList" ? "bullet_list" : "ordered_list";
      const target = view.state.schema.nodes[NODES[format]!];
      const otherDepth = depthOf(view.state, other);
      if (on && item) liftListItem(item)(view.state, view.dispatch);
      else if (otherDepth !== undefined && target) {
        // The other kind of list: convert that list in place.
        const pos = view.state.selection.$from.before(otherDepth);
        view.dispatch(view.state.tr.setNodeMarkup(pos, target));
      } else
        editor.action(
          callCommand(format === "orderedList" ? wrapInOrderedListCommand.key : wrapInBulletListCommand.key),
        );
      break;
    }
    case "quote":
      if (on) liftOut(view, "blockquote");
      else editor.action(callCommand(wrapInBlockquoteCommand.key));
      break;
    case "codeBlock":
      editor.action(callCommand(on ? turnIntoTextCommand.key : createCodeBlockCommand.key));
      break;
  }
  view.focus();
}

/** The depth of the nearest ancestor block named `name` around the selection start. */
function depthOf(state: EditorState, name: string): number | undefined {
  const { $from } = state.selection;
  for (let depth = $from.depth; depth > 0; depth -= 1) if ($from.node(depth).type.name === name) return depth;
  return undefined;
}

/** Lifts the selection's blocks out of their nearest `name` ancestor (not an inner list item). */
function liftOut(view: EditorView, name: string): void {
  const { $from, $to } = view.state.selection;
  const range = $from.blockRange($to, (node) => node.type.name === name);
  const target = range ? liftTarget(range) : null;
  if (range && target !== null) view.dispatch(view.state.tr.lift(range, target));
}

/** The whole run of text carrying `mark` (same attributes) around `pos` in its textblock. */
function markRange(state: EditorState, pos: number, type: MarkType): { from: number; to: number } | undefined {
  const $pos = state.doc.resolve(pos);
  const parent = $pos.parent;
  const start = $pos.start();
  let index = $pos.index();
  let child = parent.maybeChild(index);
  let mark = child?.marks.find((m) => m.type === type);
  if (!mark && index > 0) {
    index -= 1;
    child = parent.maybeChild(index);
    mark = child?.marks.find((m) => m.type === type);
  }
  if (!mark) return undefined;
  let first = index;
  while (first > 0 && mark.isInSet(parent.child(first - 1).marks)) first -= 1;
  let last = index;
  while (last + 1 < parent.childCount && mark.isInSet(parent.child(last + 1).marks)) last += 1;
  let from = start;
  for (let i = 0; i < first; i += 1) from += parent.child(i).nodeSize;
  let to = from;
  for (let i = first; i <= last; i += 1) to += parent.child(i).nodeSize;
  return { from, to };
}

function applyLink(view: EditorView, on: boolean, href: string | undefined): void {
  const type = view.state.schema.marks.link;
  if (!type) return;
  const { from, to, empty } = view.state.selection;
  if (on) {
    // Remove the whole link around the caret, or the link over the selection.
    const range = empty ? markRange(view.state, from, type) : { from, to };
    if (range) view.dispatch(view.state.tr.removeMark(range.from, range.to, type));
    return;
  }
  const address = href?.trim();
  if (!address) return;
  const mark = type.create({ href: address });
  if (empty) {
    const tr = view.state.tr.insertText(address, from);
    view.dispatch(tr.addMark(from, from + address.length, mark).removeStoredMark(type));
  } else {
    view.dispatch(view.state.tr.addMark(from, to, mark));
  }
}
