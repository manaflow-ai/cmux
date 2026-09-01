export interface TerminalKeyEvent {
  key: string;
  ctrlKey: boolean;
  altKey: boolean;
  shiftKey: boolean;
  metaKey: boolean;
  isComposing?: boolean;
}

export type TerminalKeyAction =
  | { kind: "text"; text: string }
  | { kind: "key"; key: string };

const namedKeys: Record<string, string> = {
  Enter: "enter",
  Tab: "tab",
  Escape: "escape",
  Backspace: "backspace",
  Delete: "delete",
  Insert: "insert",
  ArrowUp: "up",
  ArrowDown: "down",
  ArrowLeft: "left",
  ArrowRight: "right",
  Home: "home",
  End: "end",
  PageUp: "pageup",
  PageDown: "pagedown",
};

const ignoredKeys = new Set([
  "Alt",
  "AltGraph",
  "CapsLock",
  "Control",
  "Dead",
  "Meta",
  "NumLock",
  "Process",
  "ScrollLock",
  "Shift",
  "Unidentified",
]);

function modifierPrefix(event: TerminalKeyEvent): string {
  return [event.ctrlKey ? "ctrl" : null, event.altKey ? "alt" : null, event.shiftKey ? "shift" : null]
    .filter((value): value is string => value !== null)
    .join("+");
}

function namedKeyAction(event: TerminalKeyEvent, key: string): TerminalKeyAction {
  const prefix = modifierPrefix(event);
  return { kind: "key", key: prefix.length === 0 ? key : `${prefix}+${key}` };
}

function controlText(key: string): string | null {
  if (key === " " || key === "@" || key === "2") return "\u0000";
  if (key === "?") return "\u007f";
  const normalized = key.toUpperCase();
  if (normalized.length !== 1) return null;
  const code = normalized.charCodeAt(0);
  if (code >= 0x41 && code <= 0x5f) return String.fromCharCode(code & 0x1f);
  return null;
}

function isSingleCodePoint(value: string): boolean {
  return Array.from(value).length === 1;
}

/**
 * Keep the browser's Command shortcuts intact, but mirror the small set of
 * macOS editing chords that Ghostty sends to a terminal. These are raw
 * readline-compatible bytes rather than named keys, so the behavior does not
 * depend on the remote terminal's application-key or Kitty-keyboard mode.
 */
function macEditingAction(event: TerminalKeyEvent): TerminalKeyAction | null {
  const command = event.metaKey && !event.ctrlKey && !event.altKey && !event.shiftKey;
  const option = event.altKey && !event.metaKey && !event.ctrlKey && !event.shiftKey;
  if (!command && !option) return null;

  switch (event.key) {
    case "Backspace":
      return {
        kind: "text",
        // Command+Backspace is Ctrl-U. Option+Backspace is ESC DEL, which is
        // the readline word-delete sequence and matches Ghostty's native path.
        text: command ? "\u0015" : "\u001b\u007f",
      };
    case "Delete":
      return {
        kind: "text",
        // Command+ForwardDelete is Ctrl-K. Option+ForwardDelete is ESC d,
        // readline's forward-word deletion sequence.
        text: command ? "\u000b" : "\u001bd",
      };
    case "ArrowLeft":
      return {
        kind: "text",
        // Command+Left moves to the line start. Option+Left moves one word.
        text: command ? "\u0001" : "\u001bb",
      };
    case "ArrowRight":
      return {
        kind: "text",
        // Command+Right moves to the line end. Option+Right moves one word.
        text: command ? "\u0005" : "\u001bf",
      };
    default:
      return null;
  }
}

/**
 * Returns true only for editing chords that the browser may consume before
 * xterm receives them. Option+letter input is intentionally excluded: it is
 * ordinary terminal text and must keep the generic ESC-prefixed encoding.
 */
export function isMacEditingChord(event: TerminalKeyEvent): boolean {
  return !event.isComposing && macEditingAction(event) !== null;
}

export function encodeTerminalKey(event: TerminalKeyEvent): TerminalKeyAction | null {
  if (event.isComposing || ignoredKeys.has(event.key)) return null;
  if (event.metaKey || event.altKey) {
    const editing = macEditingAction(event);
    if (editing !== null) return editing;
    // Preserve browser Command shortcuts and generic Option text. Command
    // events must not fall through to text encoding, while Option events do.
    if (event.metaKey) return null;
  }

  if (event.key === "Tab" && event.shiftKey && !event.ctrlKey && !event.altKey) {
    return { kind: "key", key: "backtab" };
  }

  const named = namedKeys[event.key] ?? (/^F(?:[1-9]|1\d|2[0-4])$/.test(event.key) ? event.key.toLowerCase() : null);
  if (named !== null) return namedKeyAction(event, named);

  if (!isSingleCodePoint(event.key)) return null;
  if (event.ctrlKey) {
    const encoded = controlText(event.key);
    if (encoded !== null) {
      return { kind: "text", text: `${event.altKey ? "\u001b" : ""}${encoded}` };
    }
    return namedKeyAction(event, event.key.toLowerCase());
  }
  if (event.altKey) return { kind: "text", text: `\u001b${event.key}` };
  return { kind: "text", text: event.key };
}
