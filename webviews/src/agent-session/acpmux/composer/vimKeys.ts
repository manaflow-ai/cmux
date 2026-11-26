// Minimal modal vim for the agent pane's prompt composer (`agentPane.composerVimKeys`, off by
// default). Pure: the composer passes the key, the prompt's plain text and the caret; this answers
// what the key does. Nothing here touches the DOM, so every key is unit tested (vimKeys.test.ts).
//
// Insert mode types as the composer always does (Return sends); only Esc leaves it. Normal mode
// takes every plain letter, digit and symbol so none types into the draft, and leaves chords
// (Cmd, Ctrl, Alt), arrows, Return, Tab and the other named keys to the composer.

export type VimMode = "normal" | "insert";

export type VimState = {
  mode: VimMode;
  /// A first `d` waiting for its second.
  pending: "" | "d";
};

export const VIM_INITIAL: VimState = { mode: "insert", pending: "" };

export type VimKey = {
  key: string;
  ctrlKey?: boolean;
  metaKey?: boolean;
  altKey?: boolean;
};

export type VimResult = {
  /// False: the composer handles the key as it always does (and the caller must not prevent it).
  handled: boolean;
  state: VimState;
  /// The text to write (omitted: unchanged) and where the caret goes.
  value?: string;
  caret?: number;
  /// `u`: the field's own undo.
  undo?: boolean;
};

const NOT_HANDLED = (state: VimState): VimResult => ({ handled: false, state });

function lineStart(text: string, at: number): number {
  return text.lastIndexOf("\n", at - 1) + 1;
}

function lineEnd(text: string, at: number): number {
  const end = text.indexOf("\n", at);
  return end < 0 ? text.length : end;
}

/// The last place a normal-mode caret may rest on this line: on its last character, or the start
/// of an empty line.
function lastOn(text: string, start: number, end: number): number {
  return Math.max(start, end - 1);
}

function firstNonBlank(text: string, at: number): number {
  const start = lineStart(text, at);
  const end = lineEnd(text, at);
  let i = start;
  while (i < end && (text[i] === " " || text[i] === "\t")) i += 1;
  return i < end ? i : start;
}

/// 0 space, 1 word character, 2 other punctuation. A line break is space, as `w` crosses it.
function charClass(ch: string): 0 | 1 | 2 {
  if (/\s/.test(ch)) return 0;
  return /[\p{L}\p{N}_]/u.test(ch) ? 1 : 2;
}

export function wordForward(text: string, at: number): number {
  const last = Math.max(0, text.length - 1);
  let i = at;
  const cls = i < text.length ? charClass(text[i]!) : 0;
  if (cls !== 0) while (i < text.length && charClass(text[i]!) === cls) i += 1;
  while (i < text.length && charClass(text[i]!) === 0) {
    // An empty line is a word of its own.
    if (text[i] === "\n" && i > at && text[i + 1] === "\n") return i + 1;
    i += 1;
  }
  return Math.min(i, last);
}

export function wordBack(text: string, at: number): number {
  let i = at - 1;
  while (i > 0 && charClass(text[i]!) === 0) i -= 1;
  if (i <= 0) return 0;
  const cls = charClass(text[i]!);
  while (i > 0 && charClass(text[i - 1]!) === cls) i -= 1;
  return i;
}

export function wordEnd(text: string, at: number): number {
  const last = Math.max(0, text.length - 1);
  let i = at + 1;
  while (i < text.length && charClass(text[i]!) === 0) i += 1;
  if (i >= text.length) return last;
  const cls = charClass(text[i]!);
  while (i + 1 < text.length && charClass(text[i + 1]!) === cls) i += 1;
  return i;
}

function vertical(text: string, at: number, step: 1 | -1): number {
  const start = lineStart(text, at);
  const column = at - start;
  if (step < 0) {
    if (start === 0) return at;
    const prevEnd = start - 1;
    const prevStart = lineStart(text, prevEnd);
    return Math.min(prevStart + column, lastOn(text, prevStart, prevEnd));
  }
  const end = lineEnd(text, at);
  if (end >= text.length) return at;
  const nextStart = end + 1;
  const nextEnd = lineEnd(text, nextStart);
  return Math.min(nextStart + column, lastOn(text, nextStart, nextEnd));
}

function toInsert(caret: number, value?: string): VimResult {
  return { handled: true, state: { mode: "insert", pending: "" }, caret, ...(value === undefined ? {} : { value }) };
}

function stay(state: VimState, caret: number, value?: string): VimResult {
  return { handled: true, state: { ...state, pending: "" }, caret, ...(value === undefined ? {} : { value }) };
}

/// What `event` does in the prompt holding `text` with the caret at `caret` (a collapsed caret; a
/// selection is the composer's: `caret` is its end).
export function handleVimKey(state: VimState, event: VimKey, text: string, caret: number): VimResult {
  const { key } = event;
  if (state.mode === "insert") {
    if (key !== "Escape" || event.ctrlKey || event.metaKey || event.altKey) return NOT_HANDLED(state);
    // Leaving insert steps the caret back onto a character, as vim does.
    const start = lineStart(text, caret);
    return stay({ mode: "normal", pending: "" }, caret > start ? caret - 1 : caret);
  }
  // Normal mode.
  if (event.metaKey || event.altKey) return NOT_HANDLED(state);
  if (key === "Escape") {
    // A pending d ends; a bare Esc is the composer's (it may stop the turn).
    if (state.pending) return stay(state, caret);
    return NOT_HANDLED(state);
  }
  if (event.ctrlKey || key.length !== 1) return NOT_HANDLED(state);

  const at = Math.min(caret, text.length);
  const start = lineStart(text, at);
  const end = lineEnd(text, at);

  if (state.pending === "d") {
    if (key !== "d") return stay(state, at);
    // dd: the whole line and one line break; the caret lands on the first non-blank of the line
    // that takes its place (the one before it, when the last line went).
    const lastLine = end >= text.length;
    const from = lastLine && start > 0 ? start - 1 : start;
    const to = lastLine ? end : end + 1;
    const value = text.slice(0, from) + text.slice(to);
    const landed = lastLine && start > 0 ? lineStart(value, value.length) : Math.min(start, value.length);
    return stay(state, firstNonBlank(value, landed), value);
  }

  switch (key) {
    case "i":
      return toInsert(at);
    case "a":
      return toInsert(end > start ? at + 1 : at);
    case "I":
      return toInsert(firstNonBlank(text, at));
    case "A":
      return toInsert(end);
    case "o": {
      const value = `${text.slice(0, end)}\n${text.slice(end)}`;
      return toInsert(end + 1, value);
    }
    case "h":
      return stay(state, at > start ? at - 1 : at);
    case "l":
      return stay(state, at < lastOn(text, start, end) ? at + 1 : at);
    case "j":
      return stay(state, vertical(text, at, 1));
    case "k":
      return stay(state, vertical(text, at, -1));
    case "0":
      return stay(state, start);
    case "$":
      return stay(state, lastOn(text, start, end));
    case "w":
      return stay(state, wordForward(text, at));
    case "b":
      return stay(state, wordBack(text, at));
    case "e":
      return stay(state, wordEnd(text, at));
    case "x": {
      if (at >= end) return stay(state, at);
      const value = text.slice(0, at) + text.slice(at + 1);
      return stay(state, Math.min(at, lastOn(value, start, end - 1)), value);
    }
    case "d":
      return { handled: true, state: { ...state, pending: "d" }, caret: at };
    case "u":
      return { handled: true, state: { ...state, pending: "" }, caret: at, undo: true };
    default:
      // Every other plain key is swallowed, so it never types into the draft.
      return stay(state, at);
  }
}
