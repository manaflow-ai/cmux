// VS Code and Zed key strings to Monaco keybindings, for `editor.keybindings` (cmux.json, and the
// rules imported from the user's VS Code `keybindings.json` or Zed `keymap.json`). Pure: Monaco's
// `KeyMod` and `KeyCode` come in as a parameter, so tests run without Monaco.
//
// A key string is one chord or two separated by a space: `cmd+shift+l`, `cmd+k cmd+0` (VS Code),
// `cmd-shift-l`, `cmd-k cmd-0` (Zed). Modifiers: cmd/meta/super, ctrl/control, alt/option, shift.
// On macOS Monaco's `CtrlCmd` is Command and `WinCtrl` is Control.

export interface MonacoKeyApi {
  KeyMod: {
    CtrlCmd: number;
    Shift: number;
    Alt: number;
    WinCtrl: number;
    chord(first: number, second: number): number;
  };
  KeyCode: Record<string, number>;
}

/** One rule for `monaco.editor.addKeybindingRules`. A `-command` rule removes that command's key. */
export interface KeybindingRule {
  keybinding: number;
  command: string;
  when?: string;
}

/** An `editor.keybindings` entry as written (VS Code's `keybindings.json` shape). */
export interface KeybindingEntry {
  key: string;
  command: string;
  when?: string;
}

const NAMED: Record<string, string> = {
  up: "UpArrow",
  down: "DownArrow",
  left: "LeftArrow",
  right: "RightArrow",
  enter: "Enter",
  return: "Enter",
  escape: "Escape",
  esc: "Escape",
  tab: "Tab",
  space: "Space",
  backspace: "Backspace",
  delete: "Delete",
  home: "Home",
  end: "End",
  pageup: "PageUp",
  pagedown: "PageDown",
  insert: "Insert",
  "[": "BracketLeft",
  "]": "BracketRight",
  ";": "Semicolon",
  "'": "Quote",
  ",": "Comma",
  ".": "Period",
  "/": "Slash",
  "\\": "Backslash",
  "`": "Backquote",
  "-": "Minus",
  "=": "Equal",
};

function keyCodeName(key: string): string | null {
  if (/^[a-z]$/.test(key)) return `Key${key.toUpperCase()}`;
  if (/^[0-9]$/.test(key)) return `Digit${key}`;
  if (/^f([1-9]|1[0-9])$/.test(key)) return key.toUpperCase();
  return NAMED[key] ?? null;
}

/** One chord (`cmd+shift+l`, `cmd-shift-l`) as a Monaco key number, or null when it is not one. */
export function parseChord(text: string, api: MonacoKeyApi): number | null {
  const chord = text.trim().toLowerCase();
  if (!chord) return null;
  // `+` and `-` separate parts; a trailing `+`, `-`, `=` is the key itself (`cmd+-`, `cmd-=`).
  const parts: string[] = [];
  let current = "";
  for (let index = 0; index < chord.length; index += 1) {
    const char = chord[index]!;
    if ((char === "+" || char === "-") && current !== "" && index < chord.length - 1) {
      parts.push(current);
      current = "";
    } else {
      current += char;
    }
  }
  parts.push(current);
  const key = parts.pop()!;
  let value = 0;
  for (const part of parts) {
    switch (part) {
      case "cmd":
      case "meta":
      case "super":
      case "win":
        value |= api.KeyMod.CtrlCmd;
        break;
      case "ctrl":
      case "control":
        value |= api.KeyMod.WinCtrl;
        break;
      case "alt":
      case "option":
      case "opt":
        value |= api.KeyMod.Alt;
        break;
      case "shift":
        value |= api.KeyMod.Shift;
        break;
      default:
        return null;
    }
  }
  const name = keyCodeName(key);
  const code = name ? api.KeyCode[name] : undefined;
  return typeof code === "number" ? value | code : null;
}

/** A key string of one or two chords as a Monaco keybinding, or null. */
export function parseKeySequence(text: string, api: MonacoKeyApi): number | null {
  const chords = text.trim().split(/\s+/).filter(Boolean);
  if (chords.length === 0 || chords.length > 2) return null;
  const first = parseChord(chords[0]!, api);
  if (first === null) return null;
  if (chords.length === 1) return first;
  const second = parseChord(chords[1]!, api);
  return second === null ? null : api.KeyMod.chord(first, second);
}

/** A command a rule may name: a Monaco editor command, or its removal (`-editor.action.x`). */
const COMMAND = /^-?[a-zA-Z][\w.-]{0,127}$/;

/** VS Code `when` clauses Monaco knows; anything else (workbench contexts) is dropped. */
function editorWhen(when: unknown): string | undefined {
  if (typeof when !== "string" || when.length > 300) return undefined;
  return when.trim() || undefined;
}

/** The entries of `editor.keybindings`: VS Code's `{key, command, when}` shape, invalid ones skipped. */
export function keybindingEntries(value: unknown): KeybindingEntry[] {
  if (!Array.isArray(value)) return [];
  const out: KeybindingEntry[] = [];
  for (const item of value.slice(0, 500)) {
    if (!item || typeof item !== "object") continue;
    const { key, command, when } = item as Record<string, unknown>;
    if (typeof key !== "string" || typeof command !== "string" || !COMMAND.test(command)) continue;
    const entry: KeybindingEntry = { key, command };
    const clause = editorWhen(when);
    if (clause) entry.when = clause;
    out.push(entry);
  }
  return out;
}

/** The Monaco rules for `entries`; an entry whose key does not parse is skipped. */
export function keybindingRules(entries: KeybindingEntry[], api: MonacoKeyApi): KeybindingRule[] {
  const rules: KeybindingRule[] = [];
  for (const entry of entries) {
    const keybinding = parseKeySequence(entry.key, api);
    if (keybinding === null) continue;
    rules.push(
      entry.when ? { keybinding, command: entry.command, when: entry.when } : { keybinding, command: entry.command },
    );
  }
  return rules;
}
