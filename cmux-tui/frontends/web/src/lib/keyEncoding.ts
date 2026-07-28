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

export function encodeTerminalKey(event: TerminalKeyEvent): TerminalKeyAction | null {
  if (event.isComposing || event.metaKey || ignoredKeys.has(event.key)) return null;

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
