// Vim editing in the agent chat composer (`agentPane.vimMode`, off by default), as Claude Code's
// `/vim`. A pure step over the prompt's plain text and caret: the composer (Composer.tsx) feeds it
// each key before its own key handling and writes back what it returns (MarkdownFieldHandle
// writeText, undo). Insert mode types as the composer always did, Enter still sends; Esc enters
// Normal mode, where i a I A o return to Insert, the motions h j k l w b e 0 $ gg G move the caret
// and x dd dw cw D C u yy p edit (an operator d, c or y takes any of the motions; doubled, the line).
// A key with Cmd, Ctrl or Option, and Enter, Esc, Tab and the arrows in Normal mode, stay the
// composer's. In Normal mode every other printable key is taken, so none types into the prompt.

export type VimMode = "insert" | "normal";
type Operator = "d" | "c" | "y";

export type VimState = {
  mode: VimMode;
  /// The first key of a two-key command: an operator waiting for its motion, or `g` for `gg`.
  pending: Operator | "g" | undefined;
  /// What the last delete, change or yank took; `line` puts it back as whole lines (`p`).
  register: { text: string; line: boolean };
};

export const VIM_START: VimState = { mode: "insert", pending: undefined, register: { text: "", line: false } };

export type VimKey = { key: string; ctrl?: boolean; meta?: boolean; alt?: boolean };
/// The prompt as plain text (blocks joined by "\n") and the caret's offset in it.
export type VimText = { value: string; caret: number };

export type VimStep = {
  state: VimState;
  /// The key was vim's: the composer stops it (preventDefault) and runs none of its own handling.
  handled: boolean;
  /// The prompt and caret to write, when either changed.
  text?: VimText;
  /// Undo the prompt's last edit (`u`).
  undo?: boolean;
};

const lineStart = (value: string, at: number) => value.lastIndexOf("\n", at - 1) + 1;
const lineEnd = (value: string, at: number) => {
  const end = value.indexOf("\n", at);
  return end < 0 ? value.length : end;
};
/// Where Normal mode's caret may sit on the line at `at`: on its last character, or its start if empty.
const lastOnLine = (value: string, at: number) => Math.max(lineStart(value, at), lineEnd(value, at) - 1);
const clampNormal = (value: string, at: number) => Math.min(Math.max(0, at), lastOnLine(value, Math.max(0, at)));

/// 0 blank (a space or a line break), 1 a word character, 2 punctuation: vim's `word` classes.
function charClass(ch: string | undefined): 0 | 1 | 2 {
  if (ch === undefined || /\s/.test(ch)) return 0;
  return /[\p{L}\p{N}_]/u.test(ch) ? 1 : 2;
}

function wordForward(value: string, at: number): number {
  let i = at;
  const start = charClass(value[i]);
  if (start !== 0) while (i < value.length && charClass(value[i]) === start) i += 1;
  while (i < value.length && charClass(value[i]) === 0) i += 1;
  return i;
}

function wordEnd(value: string, at: number): number {
  let i = at + 1;
  while (i < value.length && charClass(value[i]) === 0) i += 1;
  if (i >= value.length) return Math.max(0, value.length - 1);
  const cls = charClass(value[i]);
  while (i + 1 < value.length && charClass(value[i + 1]) === cls) i += 1;
  return i;
}

function wordBack(value: string, at: number): number {
  let i = at - 1;
  while (i > 0 && charClass(value[i]) === 0) i -= 1;
  if (i <= 0) return 0;
  const cls = charClass(value[i]);
  while (i > 0 && charClass(value[i - 1]) === cls) i -= 1;
  return i;
}

/// The caret on the line `delta` lines away, in the same column where that line is long enough.
function verticalMove(value: string, at: number, delta: number): number {
  const start = lineStart(value, at);
  const column = at - start;
  let target = start;
  if (delta > 0) {
    const end = lineEnd(value, at);
    if (end >= value.length) return at;
    target = end + 1;
  } else {
    if (start === 0) return at;
    target = lineStart(value, start - 1);
  }
  return Math.min(target + column, lastOnLine(value, target));
}

/// A motion's caret, or undefined for a key that is not a motion. `g` is `gg` (the first line).
function motion(key: string, value: string, at: number): number | undefined {
  switch (key) {
    case "h":
    case "Backspace":
      return Math.max(lineStart(value, at), at - 1);
    case "l":
    case " ":
      return Math.min(lastOnLine(value, at), at + 1);
    case "j":
      return verticalMove(value, at, 1);
    case "k":
      return verticalMove(value, at, -1);
    case "w":
      return wordForward(value, at);
    case "b":
      return wordBack(value, at);
    case "e":
      return wordEnd(value, at);
    case "0":
      return lineStart(value, at);
    case "$":
      return lastOnLine(value, at);
    case "g":
      return 0;
    case "G":
      return lineStart(value, value.length);
    default:
      return undefined;
  }
}

/// The span an operator takes with `key` from `at` ([from, to), plain-text offsets), or undefined.
function operatorSpan(op: Operator, key: string, value: string, at: number): [number, number] | undefined {
  // `cw` on a word changes to the word's end, not up to the next word (vim's own exception).
  if (op === "c" && key === "w" && charClass(value[at]) !== 0) return [at, wordEnd(value, at) + 1];
  const to = motion(key, value, at);
  if (to === undefined) return undefined;
  // The inclusive motions take the character they land on.
  if (key === "e" || key === "$") return [Math.min(at, to), Math.min(value.length, Math.max(at, to) + 1)];
  // `dw` on a line's last word stops at its end, keeping the line break.
  if (key === "w") return [at, Math.min(to, lineEnd(value, at))];
  if (key === "j" || key === "k" || key === "g" || key === "G") return undefined;
  return [Math.min(at, to), Math.max(at, to)];
}

/// The line at `at` with its line break, as `dd` and `yy` take it.
function lineSpan(value: string, at: number): { from: number; to: number; text: string } {
  const start = lineStart(value, at);
  const end = lineEnd(value, at);
  const text = value.slice(start, end);
  if (end < value.length) return { from: start, to: end + 1, text };
  // The last line takes the line break before it, so no empty line is left.
  return { from: Math.max(0, start - 1), to: end, text };
}

function cut(value: string, from: number, to: number): string {
  return value.slice(0, from) + value.slice(to);
}

/// One key in the composer with vim mode on.
export function vimKey(state: VimState, key: VimKey, text: VimText): VimStep {
  const { value } = text;
  const caret = Math.min(Math.max(0, text.caret), value.length);
  if (state.mode === "insert") {
    if (key.key !== "Escape" || key.ctrl || key.meta || key.alt) return { state, handled: false };
    // Esc leaves Insert with the caret on the character before it, as vim does.
    const at = caret > lineStart(value, caret) ? caret - 1 : caret;
    return { state: { ...state, mode: "normal", pending: undefined }, handled: true, text: { value, caret: at } };
  }
  const clear = { ...state, pending: undefined };
  // Shortcuts and the composer's own keys (Enter sends, Esc arms Stop, Tab, the arrows) stay its own.
  if (key.ctrl || key.meta || key.alt || (key.key.length !== 1 && key.key !== "Backspace")) {
    return { state: clear, handled: false };
  }
  const k = key.key;
  const at = clampNormal(value, caret);
  const normal = (next: VimState, newValue: string, newCaret: number): VimStep => ({
    state: next,
    handled: true,
    text: { value: newValue, caret: clampNormal(newValue, newCaret) },
  });
  const insert = (next: VimState, newValue: string, newCaret: number): VimStep => ({
    state: { ...next, mode: "insert", pending: undefined },
    handled: true,
    text: { value: newValue, caret: newCaret },
  });

  if (state.pending === "g") {
    return k === "g" ? normal(clear, value, 0) : { state: clear, handled: true };
  }
  if (state.pending === "d" || state.pending === "c" || state.pending === "y") {
    const op = state.pending;
    if (k === op) {
      const line = lineSpan(value, at);
      const register = { text: line.text, line: true };
      if (op === "y") return { state: { ...clear, register }, handled: true };
      if (op === "c") {
        const start = lineStart(value, at);
        const end = lineEnd(value, at);
        return insert({ ...clear, register }, cut(value, start, end), start);
      }
      const next = cut(value, line.from, line.to);
      return normal({ ...clear, register }, next, lineStart(next, Math.min(line.from, next.length)));
    }
    const span = operatorSpan(op, k, value, at);
    if (!span) return { state: clear, handled: true };
    const [from, to] = span;
    const register = { text: value.slice(from, to), line: false };
    if (op === "y") return normal({ ...clear, register }, value, from);
    const next = cut(value, from, to);
    if (op === "c") return insert({ ...clear, register }, next, from);
    return normal({ ...clear, register }, next, from);
  }

  switch (k) {
    case "i":
      return insert(clear, value, at);
    case "a":
      return insert(clear, value, Math.min(lineEnd(value, at), at + 1));
    case "A":
      return insert(clear, value, lineEnd(value, at));
    case "I": {
      let start = lineStart(value, at);
      const end = lineEnd(value, at);
      while (start < end && /[ \t]/.test(value[start] ?? "")) start += 1;
      return insert(clear, value, start);
    }
    case "o": {
      const end = lineEnd(value, at);
      return insert(clear, `${value.slice(0, end)}\n${value.slice(end)}`, end + 1);
    }
    case "d":
    case "c":
    case "y":
    case "g":
      return { state: { ...state, pending: k }, handled: true };
    case "x": {
      if (at >= lineEnd(value, at)) return { state: clear, handled: true };
      const register = { text: value.slice(at, at + 1), line: false };
      return normal({ ...clear, register }, cut(value, at, at + 1), at);
    }
    case "D":
    case "C": {
      const end = lineEnd(value, at);
      const register = { text: value.slice(at, end), line: false };
      const next = cut(value, at, end);
      return k === "C"
        ? insert({ ...clear, register }, next, at)
        : normal({ ...clear, register }, next, Math.max(lineStart(value, at), at - 1));
    }
    case "u":
      return { state: clear, handled: true, undo: true };
    case "p": {
      const { register } = state;
      if (!register.text && !register.line) return { state: clear, handled: true };
      if (register.line) {
        const end = lineEnd(value, at);
        return normal(clear, `${value.slice(0, end)}\n${register.text}${value.slice(end)}`, end + 1);
      }
      const place = at < lineEnd(value, at) ? at + 1 : at;
      return normal(
        clear,
        value.slice(0, place) + register.text + value.slice(place),
        place + register.text.length - 1,
      );
    }
    default: {
      const to = motion(k, value, at);
      // A key vim does not know does nothing in Normal mode; it never types.
      if (to === undefined) return { state: clear, handled: true };
      return normal(clear, value, to);
    }
  }
}
