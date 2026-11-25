// The web side of the one keymap layer (design/keyboard-style.md): `app.keyStyle` (the keys lists
// answer to: standard, vim or emacs) and `app.shortcutLayout` (shortcuts follow the layout's
// characters, or the US key positions by KeyboardEvent.code). The table is
// schemas/keymap/key-styles.json, the same file cmux-tui/crates/cmux-keymap reads for the Swift
// surfaces, and keyStyle.test.ts runs every case of schemas/keymap/key-vectors.json through this
// file, as the crate's tests/vectors.rs does. Its `$comment` fields are the spec; this file only
// follows them. Surfaces use it through useListKeys.ts.
import table from "../../../schemas/keymap/key-styles.json";

export type KeyStyle = "standard" | "vim" | "emacs";
export type ShortcutLayout = "followLayout" | "qwertyPositions";
export type KeyMod = "cmd" | "ctrl" | "alt" | "shift";
export type ListCommand =
  | "list.next"
  | "list.previous"
  | "list.first"
  | "list.last"
  | "list.pageDown"
  | "list.pageUp"
  | "list.open"
  | "list.back"
  | "list.search"
  | "list.leave";
export type ListOutcome = "pass" | "pending" | ListCommand;

/// One key press as the keymap sees it (the vectors' event): `code` the physical key (W3C
/// KeyboardEvent.code), `key` what the layout types on it without modifiers (lowercase; "Dead" for
/// a dead key; a named key such as "escape" or "arrowdown"), `shiftedKey` what it types with Shift.
export type KeyEvent = { code: string; key: string; shiftedKey?: string; mods: readonly KeyMod[] };

export const KEY_STYLES: readonly KeyStyle[] = ["standard", "vim", "emacs"];
export const SHORTCUT_LAYOUTS: readonly ShortcutLayout[] = ["followLayout", "qwertyPositions"];
export const LIST_COMMANDS = table.commands as unknown as readonly ListCommand[];

type Row = { keys: readonly string[]; command: ListCommand; inText?: boolean };
const STYLES = table.styles as unknown as Record<KeyStyle, readonly Row[]>;

/// What each physical key types on the US layout (qwertyPositions, and the followLayout fallback).
const QWERTY_BY_CODE = new Map<string, string>(table.keys.map((key): [string, string] => [key.code, key.qwerty]));

const CMD = 1;
const CTRL = 2;
const ALT = 4;
const SHIFT = 8;
const MOD_BITS: Record<string, number> = { cmd: CMD, ctrl: CTRL, alt: ALT, shift: SHIFT };

/// Named keys of the stroke syntax, by the lowercased DOM key (or code) that types them.
const NAMED_BY_DOM: Record<string, string> = {
  escape: "escape",
  esc: "escape",
  enter: "enter",
  numpadenter: "enter",
  arrowup: "up",
  arrowdown: "down",
  arrowleft: "left",
  arrowright: "right",
  pageup: "pageup",
  pagedown: "pagedown",
  tab: "tab",
  home: "home",
  end: "end",
  backspace: "backspace",
  delete: "delete",
};
const NAMED = new Set(Object.values(NAMED_BY_DOM));

/// The US layout's unshifted punctuation for its shifted punctuation. The DOM never says what a key
/// types without Shift while Shift is held, so keyEventFromDom reads a shifted punctuation mark as
/// its US key's (Dvorak's Shift-] types "}", read as "]"). Digits are left out: the digit row is
/// matched by its code, and AZERTY's Shift-$ ("*") must not read as Shift-8.
const US_UNSHIFTED: Record<string, string> = {
  "~": "`",
  _: "-",
  "+": "=",
  "{": "[",
  "}": "]",
  "|": "\\",
  ":": ";",
  '"': "'",
  "<": ",",
  ">": ".",
  "?": "/",
};

type Stroke = { mods: number; key: string };
const strokes = new Map<string, Stroke | null>();

/// A keybindings.json stroke ("cmd+shift+]", "shift+g", "escape", "cmd++"); null for one this
/// layer does not know (an unknown modifier, no key).
function parseStroke(text: string): Stroke | null {
  const cached = strokes.get(text);
  if (cached !== undefined) return cached;
  let key: string;
  let rest: string;
  if (text === "+") [key, rest] = ["+", ""];
  else if (text.endsWith("++")) [key, rest] = ["+", text.slice(0, -2)];
  else {
    const split = text.lastIndexOf("+");
    [key, rest] = [text.slice(split + 1), split < 0 ? "" : text.slice(0, split)];
  }
  let mods = 0;
  let parsed: Stroke | null = null;
  if (key) {
    parsed = { mods: 0, key: key.toLowerCase() };
    for (const mod of rest ? rest.split("+") : []) {
      const bit = MOD_BITS[mod.toLowerCase()];
      if (!bit) {
        parsed = null;
        break;
      }
      mods |= bit;
    }
    if (parsed) parsed.mods = mods;
    if (parsed && parsed.key.length > 1 && !NAMED.has(parsed.key)) parsed = null;
  }
  strokes.set(text, parsed);
  return parsed;
}

const modMask = (mods: readonly KeyMod[]) => mods.reduce((mask, mod) => mask | (MOD_BITS[mod] ?? 0), 0);
const isLetter = (char: string) => char.toLowerCase() !== char.toUpperCase();
/// One printable ASCII character: what a binding can name.
const isAsciiChar = (char: string) => /^[\x21-\x7e]$/.test(char);

function namedKey(event: KeyEvent): string | undefined {
  return NAMED_BY_DOM[event.key.toLowerCase()] ?? NAMED_BY_DOM[event.code.toLowerCase()];
}

function followLayoutMatches(stroke: Stroke, event: KeyEvent, mods: number): boolean {
  if (mods === stroke.mods) {
    // The character the layout types (today's behavior).
    if (event.key === stroke.key) return true;
    // A digit-row key also counts as its digit (AZERTY's & key is 1).
    const digit = /^Digit(\d)$/.exec(event.code)?.[1];
    if (digit !== undefined && digit === stroke.key) return true;
    // A dead key, or one that types a non-ASCII character, counts as its US position (QWERTZ's ü is [).
    if ((event.key === "Dead" || !isAsciiChar(event.key)) && QWERTY_BY_CODE.get(event.code) === stroke.key) return true;
  }
  // A character the layout only types with Shift matches a binding without Shift (AZERTY's / is
  // Shift-:), but never a letter's capital (Cmd-Shift-Z stays Cmd-Shift-Z).
  if (mods & SHIFT && (mods & ~SHIFT) === stroke.mods) {
    const shifted = event.shiftedKey;
    if (shifted && shifted !== "Dead" && !isLetter(shifted) && shifted === stroke.key) return true;
  }
  return false;
}

/// Whether `binding` (keybindings.json stroke syntax) matches `event` in `layout`'s mode.
/// Modifiers always match exactly: Cmd-J is never J.
export function strokeMatches(layout: ShortcutLayout, binding: string, event: KeyEvent): boolean {
  const stroke = parseStroke(binding);
  if (!stroke) return false;
  const mods = modMask(event.mods);
  const named = namedKey(event);
  if (NAMED.has(stroke.key)) return mods === stroke.mods && named === stroke.key;
  if (named) return false;
  if (layout === "qwertyPositions") {
    const us = QWERTY_BY_CODE.get(event.code);
    // A key with no US position in the table (a numpad key, a code the browser leaves empty)
    // follows the layout.
    if (us !== undefined) return mods === stroke.mods && us === stroke.key;
  }
  return followLayoutMatches(stroke, event, mods);
}

/// The keymap's event for a DOM key press. With Shift held the DOM's `key` is the shifted
/// character and the unshifted one is unknown: a letter's is its lowercase, a US shifted
/// punctuation mark's is its US key's (US_UNSHIFTED), anything else stands for itself.
export function keyEventFromDom(
  e: Pick<KeyboardEvent, "code" | "key" | "metaKey" | "ctrlKey" | "altKey" | "shiftKey">,
): KeyEvent {
  const mods: KeyMod[] = [];
  if (e.metaKey) mods.push("cmd");
  if (e.ctrlKey) mods.push("ctrl");
  if (e.altKey) mods.push("alt");
  if (e.shiftKey) mods.push("shift");
  const raw = e.key ?? "";
  const code = e.code ?? "";
  if (raw === "Dead") return e.shiftKey ? { code, key: "Dead", shiftedKey: "Dead", mods } : { code, key: "Dead", mods };
  if (!e.shiftKey || raw.length !== 1) return { code, key: raw.toLowerCase(), mods };
  const key = isLetter(raw) ? raw.toLowerCase() : (US_UNSHIFTED[raw] ?? raw);
  return { code, key, shiftedKey: raw, mods };
}

/// One list's key layer for `style`: feed it every key press the list sees.
export type ListKeys = {
  /// A command, "pending" (the first g of gg: the next key decides) or "pass" (the surface's own).
  /// `inText`: a text field has the keyboard, so only the style's `inText` rows apply.
  feed(event: KeyEvent, inText: boolean): ListOutcome;
  /// Drops a pending first key (its timeout, a blur).
  reset(): void;
};

export function createListKeys(style: KeyStyle, layout: ShortcutLayout): ListKeys {
  const rows = STYLES[style] ?? [];
  let pending: readonly Row[] = [];
  return {
    feed(event, inText) {
      const live = inText ? rows.filter((row) => row.inText === true) : rows;
      const started = pending;
      pending = [];
      // The second key of a sequence; any other key drops the first and is read on its own.
      const second = started.find((row) => live.includes(row) && strokeMatches(layout, row.keys[1]!, event));
      if (second) return second.command;
      const single = live.find((row) => row.keys.length === 1 && strokeMatches(layout, row.keys[0]!, event));
      if (single) return single.command;
      const firsts = live.filter((row) => row.keys.length === 2 && strokeMatches(layout, row.keys[0]!, event));
      if (firsts.length === 0) return "pass";
      pending = firsts;
      return "pending";
    },
    reset() {
      pending = [];
    },
  };
}

/// Where typing belongs to a text field: an input that takes text, a textarea, a select, a
/// contenteditable element or anything inside one, or a [role=textbox]. The one shared form of the
/// selectors ComposerBox.tsx (CARD_OWN_PRESS), composerFocus.ts (OWNS_KEYS) and needsYouModel.ts
/// (TYPES_HERE) each copy.
export const EDITABLE_SELECTOR =
  'input, textarea, select, [contenteditable]:not([contenteditable="false"]), [role="textbox"]';
const NON_TEXT_INPUTS = new Set(["button", "checkbox", "radio", "range", "color", "file", "submit", "reset", "image"]);

export function isEditableTarget(target: EventTarget | null | undefined): boolean {
  const element = target as Element | null | undefined;
  if (!element || typeof element.closest !== "function") return false;
  const editable = element.closest(EDITABLE_SELECTOR);
  if (!editable) return false;
  if (editable.tagName === "INPUT")
    return !NON_TEXT_INPUTS.has(((editable as HTMLInputElement).type || "text").toLowerCase());
  return true;
}

/// `app.keyStyle` and `app.shortcutLayout` as the page has them.
export type KeyStyleSettings = { keyStyle: KeyStyle; shortcutLayout: ShortcutLayout };
export const KEY_STYLE_KEY = "app.keyStyle";
export const SHORTCUT_LAYOUT_KEY = "app.shortcutLayout";
export const DEFAULT_KEY_STYLE_SETTINGS: KeyStyleSettings = { keyStyle: "standard", shortcutLayout: "followLayout" };

/// Reads both from a flat map by dotted key (the host's `display` event, chatDisplay.ts); a value
/// this page does not know keeps the default.
export function readKeyStyleSettings(values: unknown): KeyStyleSettings {
  const raw = (values && typeof values === "object" ? values : {}) as Record<string, unknown>;
  const style = raw[KEY_STYLE_KEY];
  const layout = raw[SHORTCUT_LAYOUT_KEY];
  return {
    keyStyle: KEY_STYLES.includes(style as KeyStyle) ? (style as KeyStyle) : DEFAULT_KEY_STYLE_SETTINGS.keyStyle,
    shortcutLayout: SHORTCUT_LAYOUTS.includes(layout as ShortcutLayout)
      ? (layout as ShortcutLayout)
      : DEFAULT_KEY_STYLE_SETTINGS.shortcutLayout,
  };
}

let current = DEFAULT_KEY_STYLE_SETTINGS;
const listeners = new Set<() => void>();

/// The host's values (the `display` event's map): every list on the page follows at once.
export function configureKeyStyle(values: unknown): void {
  const next = readKeyStyleSettings(values);
  if (next.keyStyle === current.keyStyle && next.shortcutLayout === current.shortcutLayout) return;
  current = next;
  for (const listener of listeners) listener();
}

export function subscribeKeyStyle(listener: () => void): () => void {
  listeners.add(listener);
  return () => void listeners.delete(listener);
}

export function keyStyleSnapshot(): KeyStyleSettings {
  return current;
}
