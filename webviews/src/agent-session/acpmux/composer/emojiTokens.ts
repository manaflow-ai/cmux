import type { Node as ProseNode } from "@milkdown/kit/prose/model";
import { closeHistory } from "@milkdown/kit/prose/history";
import { type EditorState, TextSelection, type Transaction } from "@milkdown/kit/prose/state";
import { emojiTokenIn, type EmojiTrigger } from "../emojiShortcodes";
import { leafChar } from "./slashTokens";

// The prompt's `:shortcode` emoji in the editor (emojiShortcodes.ts holds the rules), as the `/`
// commands are (slashTokens.ts): the token the caret ends, read from the caret's own block, so a
// token on any line of the draft opens the menu (it read only the first paragraph before: Leo's
// `:plead` under a list, 2026-11-22: "for some reason i can't do :pleading_face: with the emoji
// here"); and the pick written over it as one undoable edit. Only the text near the caret is read.

/// How far back the caret's text is read: past the longest shortcode with its tone suffix.
const EMOJI_READ_MAX = 64;

/// The caret's block text up to the caret, a character per position; a code span's characters and
/// any attachment as U+FFFC, so no token reaches into code. Undefined with a selection, in a code
/// block, or with the caret in code.
export function emojiTextBefore(state: EditorState, max = EMOJI_READ_MAX): string | undefined {
  const { selection } = state;
  if (!selection.empty) return undefined;
  const { $from } = selection;
  const block = $from.parent;
  if (!block.isTextblock || block.type.spec.code) return undefined;
  const offset = $from.parentOffset;
  const from = Math.max(0, offset - max - 1);
  let out = "";
  let childStart = 0;
  for (let index = 0; index < block.childCount && childStart < offset; index++) {
    const child: ProseNode = block.child(index);
    const end = childStart + child.nodeSize;
    if (end > from) {
      const piece = child.isText
        ? child.marks.some((mark) => mark.type.spec.code)
          ? "\uFFFC".repeat(child.nodeSize)
          : child.text!
        : leafChar(child) + "\uFFFC".repeat(Math.max(0, child.nodeSize - 1));
      out += piece.slice(Math.max(0, from - childStart), Math.min(piece.length, offset - childStart));
    }
    childStart = end;
  }
  // Read from the middle of a long line: a token must start past the cut.
  return from > 0 ? `\uFFFC${out.slice(1)}` : out;
}

/// The emoji token the caret ends, `start` its document position; undefined with none.
export function emojiTriggerAt(state: EditorState): EmojiTrigger | undefined {
  const before = emojiTextBefore(state);
  if (before === undefined) return undefined;
  const found = emojiTokenIn(before);
  if (!found) return undefined;
  const { at, ...token } = found;
  return { ...token, start: state.selection.from - (before.length - at) };
}

/// How far back the caret's text is read for an `@` mention: a long path.
const MENTION_READ_MAX = 256;
/// `@` at a word start, then the word: no space, no second `@`, no code or attachment.
const MENTION = /(?:^|\s)@([^\s@\uFFFC]*)$/u;

/// The `@word` the caret ends, `start` the `@`'s document position.
export interface MentionTrigger {
  start: number;
  query: string;
}

/// The `@word` the caret ends, on any line of the draft, read from the editor as the `:` and `/`
/// tokens are; undefined with none, a selection, or the caret in code. It read the markdown with a
/// caret counted in the first paragraph only before, so `@` on a later line opened nothing (the
/// emoji menu's bug, Leo 2026-11-22: "for some reason i can't do :pleading_face: with the emoji
/// here").
export function mentionTriggerAt(state: EditorState): MentionTrigger | undefined {
  const before = emojiTextBefore(state, MENTION_READ_MAX);
  if (before === undefined) return undefined;
  const found = MENTION.exec(before);
  if (!found) return undefined;
  const query = found[1]!;
  return { start: state.selection.from - query.length - 1, query };
}

/// The edit that writes `insert` over the `back` characters before the caret, the caret after it:
/// its own undo step, so ⌘Z gives back what was typed. `space` adds one space after it unless the
/// text after the caret starts with one (a line break is no space).
export function emojiEdit(state: EditorState, back: number, insert: string, space: boolean): Transaction | undefined {
  const { selection } = state;
  if (!selection.empty || selection.$from.parentOffset < back) return undefined;
  const { $from } = selection;
  const next = $from.parent.textBetween(
    $from.parentOffset,
    Math.min($from.parent.content.size, $from.parentOffset + 1),
  );
  const text = space && !/^[ \t]/.test(next) ? `${insert} ` : insert;
  const from = $from.pos - back;
  const tr = closeHistory(state.tr).insertText(text, from, $from.pos);
  // Past the space the text already had, too: the caret is where the next word goes.
  const after = from + text.length + (space && text === insert ? 1 : 0);
  return tr.setSelection(TextSelection.create(tr.doc, after)).scrollIntoView();
}
