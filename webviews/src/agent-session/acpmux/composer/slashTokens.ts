import type { Node as ProseNode } from "@milkdown/kit/prose/model";
import { closeHistory } from "@milkdown/kit/prose/history";
import { type EditorState, Plugin, PluginKey, TextSelection, type Transaction } from "@milkdown/kit/prose/state";
import { Decoration, DecorationSet } from "@milkdown/kit/prose/view";
import {
  SLASH_WORD_MAX,
  commandSplice,
  slashTokens,
  slashTrigger,
  type SlashNames,
  type SlashTrigger,
} from "../slashCommands";
import { INLINE_NODE } from "./inlineNode";

// The prompt's `/` commands in the editor (slashCommands.ts holds the rules): the `/word` the caret
// ends, which opens the menu; the pick written over it as one undoable edit; and the blue of a
// `/name` that names a command. The blue is a decoration, so copy, send and undo see plain text.
// Everything here reads the text near the caret or the edit, never the whole prompt per key.

/// The class a command word draws with (markdownField.css).
export const SLASH_TOKEN_CLASS = "acpmux-slash-token";

/// A line break reads as one; an attachment placed in the text (or any other leaf) as U+FFFC.
const leafChar = (node: ProseNode) => (node.type.name === "hardbreak" ? "\n" : "\uFFFC");

/// The text of `block` (its content at document position `start`) from offset `from` to `to`, a
/// character per position. It starts at the child that holds `from`, found through a resolved
/// position, so the text before it is never walked.
function blockText(doc: ProseNode, block: ProseNode, start: number, from: number, to: number): string {
  if (to <= from) return "";
  const $at = doc.resolve(start + from);
  let index = $at.index();
  let childStart = from - $at.textOffset;
  let out = "";
  while (childStart < to && index < block.childCount) {
    const child = block.child(index);
    const piece = child.isText ? child.text! : leafChar(child) + "\uFFFC".repeat(Math.max(0, child.nodeSize - 1));
    out += piece.slice(Math.max(0, from - childStart), Math.min(piece.length, to - childStart));
    childStart += child.nodeSize;
    index++;
  }
  return out;
}

/// Where the prompt's first word starts, as send reads the prompt: past attachments placed in the
/// text, spaces and blank lines (send takes them out and trims), in a top-level paragraph with no
/// formatting on it. Undefined when the prompt has no such word (it starts with a heading, a quote,
/// bold text). Reads only up to that word.
export function promptLead(doc: ProseNode): number | undefined {
  let pos = 0;
  for (let index = 0; index < doc.childCount; index++) {
    const block = doc.child(index);
    if (block.type.name !== "paragraph") return undefined;
    let at = pos + 1;
    for (let child = 0; child < block.childCount; child++) {
      const node = block.child(child);
      if (node.isText) {
        const word = node.text!.search(/\S/);
        if (word >= 0) return node.marks.length ? undefined : at + word;
      } else if (node.type.name !== "hardbreak" && node.type.name !== INLINE_NODE) return undefined;
      at += node.nodeSize;
    }
    pos += block.nodeSize;
  }
  return undefined;
}

/// `lead` as an offset into text that starts at document position `from`, when it falls there.
const leadIn = (lead: number | undefined, from: number, length: number) =>
  lead !== undefined && lead >= from && lead <= from + length ? lead - from : undefined;

/// The `/word` the caret ends, or undefined (a selection, a code block or code span, no `/word`).
export function slashTriggerAt(state: EditorState): SlashTrigger | undefined {
  const { selection, doc } = state;
  if (!selection.empty) return undefined;
  const { $from } = selection;
  const block = $from.parent;
  if (!block.isTextblock || block.type.spec.code) return undefined;
  if ($from.marks().some((mark) => mark.type.spec.code)) return undefined;
  const offset = $from.parentOffset;
  const start = $from.start();
  const lo = Math.max(0, offset - SLASH_WORD_MAX - 1);
  const before = blockText(doc, block, start, lo, offset);
  return slashTrigger(before, leadIn(promptLead(doc), start + lo, before.length));
}

/// The edit that writes `/name ` over the `/word` the caret ends (and the rest of that word after
/// it), the caret after the space: its own undo step. Undefined with no `/word` at the caret.
export function commandEdit(state: EditorState, name: string): Transaction | undefined {
  const trigger = slashTriggerAt(state);
  if (!trigger) return undefined;
  const { $from } = state.selection;
  const block = $from.parent;
  const offset = $from.parentOffset;
  const hi = Math.min(block.content.size, offset + SLASH_WORD_MAX + 1);
  const after = blockText(state.doc, block, $from.start(), offset, hi);
  const splice = commandSplice(after, trigger, name, hi < block.content.size);
  const from = $from.pos - splice.back;
  // A new undo step, not merged into the letters typed just before it.
  const tr = closeHistory(state.tr).insertText(splice.text, from, $from.pos + splice.forward);
  return tr.setSelection(TextSelection.create(tr.doc, from + splice.text.length)).scrollIntoView();
}

type Meta = { names: SlashNames };
type TokenState = { names: SlashNames; set: DecorationSet; lead: number | undefined };
const key = new PluginKey<TokenState>("acpmuxSlashTokens");

/// Tells the plugin the command names changed: every command word is read again (rare: a chat's
/// list arriving or changing).
export function setSlashNames(tr: Transaction, names: SlashNames): Transaction {
  return tr.setMeta(key, { names } satisfies Meta);
}

/// The decorations of the command words in the textblock at `pos` that touch `from...to` (document
/// positions), with the old ones there taken out first.
function redecorate(
  set: DecorationSet,
  doc: ProseNode,
  block: ProseNode,
  pos: number,
  from: number,
  to: number,
  names: SlashNames,
  lead: number | undefined,
): DecorationSet {
  const start = pos + 1;
  const end = start + block.content.size;
  const a = Math.min(Math.max(from, start), end);
  const b = Math.min(Math.max(to, start), end);
  // A command word is at most SLASH_WORD_MAX long: a word reaching past this window is no command.
  const lo = Math.max(start, a - SLASH_WORD_MAX - 2);
  const hi = Math.min(end, b + SLASH_WORD_MAX + 2);
  const text = blockText(doc, block, start, lo - start, hi - start);
  const found = slashTokens(text, names, {
    lead: leadIn(lead, lo, text.length),
    from: a - lo,
    to: b - lo,
    cutStart: lo > start,
    cutEnd: hi < end,
  });
  const old = set.find(lo + found.from, lo + found.to);
  const next = old.length ? set.remove(old) : set;
  if (!found.tokens.length) return next;
  return next.add(
    doc,
    found.tokens.map(([tokenFrom, tokenTo]) =>
      Decoration.inline(lo + tokenFrom, lo + tokenTo, { class: SLASH_TOKEN_CLASS }),
    ),
  );
}

/// Runs `visit` on each textblock (not code) that `from...to` touches. The top-level blocks are
/// reached by index from a resolved position, so the blocks before the range are never walked.
function eachTextblock(doc: ProseNode, from: number, to: number, visit: (block: ProseNode, pos: number) => void): void {
  const $from = doc.resolve(Math.max(0, Math.min(from, doc.content.size)));
  const last = Math.min(doc.childCount - 1, doc.resolve(Math.max(0, Math.min(to, doc.content.size))).index(0));
  let index = Math.min($from.index(0), doc.childCount - 1);
  let pos = $from.posAtIndex(index, 0);
  for (; index <= last; index++) {
    const child = doc.child(index);
    if (child.isTextblock) {
      if (!child.type.spec.code) visit(child, pos);
    } else {
      // A list or a quote: only its own blocks in the range.
      child.nodesBetween(
        Math.max(0, from - pos - 1),
        Math.max(0, Math.min(child.content.size, to - pos - 1)),
        (node, at) => {
          if (!node.isTextblock) return true;
          if (!node.type.spec.code) visit(node, pos + 1 + at);
          return false;
        },
      );
    }
    pos += child.nodeSize;
  }
}

/// Every command word in `doc`.
function decorateAll(doc: ProseNode, names: SlashNames, lead: number | undefined): DecorationSet {
  let set = DecorationSet.empty;
  if (!names.anywhere.size && !names.leading.size) return set;
  doc.descendants((node, pos) => {
    if (!node.isTextblock) return true;
    if (!node.type.spec.code) set = redecorate(set, doc, node, pos, pos + 1, pos + 1 + node.content.size, names, lead);
    return false;
  });
  return set;
}

/// Colours each `/name` that names a command (`names()` read when the editor is made; later lists
/// come with `setSlashNames`). An edit reads again only the words around what it changed, and the
/// prompt's first word when another word becomes it.
export function slashTokensPlugin(names: () => SlashNames): Plugin {
  return new Plugin({
    key,
    state: {
      init: (_config, state) => {
        const initial = names();
        const lead = promptLead(state.doc);
        return { names: initial, set: decorateAll(state.doc, initial, lead), lead };
      },
      apply: (tr, value, _old, state): TokenState => {
        const { doc } = state;
        const meta = tr.getMeta(key) as Meta | undefined;
        if (meta) {
          const lead = promptLead(doc);
          return { names: meta.names, set: decorateAll(doc, meta.names, lead), lead };
        }
        if (!tr.docChanged) return value;
        let set = value.set.map(tr.mapping, doc);
        const lead = promptLead(doc);
        if (!value.names.anywhere.size && !value.names.leading.size) return { names: value.names, set, lead };
        // Where the edit changed the document, and where the prompt's first word was and is now:
        // a word becomes the first, or stops being it, also through an edit far before it.
        const ranges: [number, number][] = [];
        tr.mapping.maps.forEach((map, index) => {
          const later = tr.mapping.slice(index + 1);
          map.forEach((_oldFrom, _oldTo, newFrom, newTo) => {
            ranges.push([later.map(newFrom, -1), later.map(newTo, 1)]);
          });
        });
        const was = value.lead === undefined ? undefined : tr.mapping.map(value.lead);
        if (was !== lead) {
          if (was !== undefined) ranges.push([was, was]);
          if (lead !== undefined) ranges.push([lead, lead]);
        }
        for (const [from, to] of ranges)
          eachTextblock(doc, from, to, (block, pos) => {
            set = redecorate(set, doc, block, pos, from, to, value.names, lead);
          });
        return { names: value.names, set, lead };
      },
    },
    props: {
      decorations: (state) => key.getState(state)?.set,
    },
  });
}
