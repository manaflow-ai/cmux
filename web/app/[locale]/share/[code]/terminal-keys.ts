// Keyboard-event to terminal-byte translation for guest typing. Covers the
// working set a pairing guest needs (printables, control keys, arrows,
// nav/function keys); IME composition and exotic modes ride on later slices.

const CSI = "\x1b[";
const SS3 = "\x1bO";

const NAMED_KEYS: Record<string, string> = {
  Enter: "\r",
  Backspace: "\x7f",
  Tab: "\t",
  Escape: "\x1b",
  Delete: `${CSI}3~`,
  Home: `${CSI}H`,
  End: `${CSI}F`,
  PageUp: `${CSI}5~`,
  PageDown: `${CSI}6~`,
  Insert: `${CSI}2~`,
  F1: `${SS3}P`,
  F2: `${SS3}Q`,
  F3: `${SS3}R`,
  F4: `${SS3}S`,
  F5: `${CSI}15~`,
  F6: `${CSI}17~`,
  F7: `${CSI}18~`,
  F8: `${CSI}19~`,
  F9: `${CSI}20~`,
  F10: `${CSI}21~`,
  F11: `${CSI}23~`,
  F12: `${CSI}24~`,
};

const ARROWS: Record<string, string> = {
  ArrowUp: "A",
  ArrowDown: "B",
  ArrowRight: "C",
  ArrowLeft: "D",
};

/**
 * Translate a keydown into terminal input bytes, or null when the event
 * should fall through to the browser (e.g. Cmd shortcuts, bare modifiers).
 */
export function keyEventToBytes(e: {
  key: string;
  ctrlKey: boolean;
  altKey: boolean;
  metaKey: boolean;
  shiftKey: boolean;
}): string | null {
  if (e.metaKey) return null; // never swallow browser/system shortcuts

  const arrow = ARROWS[e.key];
  if (arrow) {
    if (e.ctrlKey || e.altKey || e.shiftKey) {
      // xterm modifyOtherKeys encoding: 1 + shift(1) + alt(2) + ctrl(4).
      const mod = 1 + (e.shiftKey ? 1 : 0) + (e.altKey ? 2 : 0) + (e.ctrlKey ? 4 : 0);
      return `${CSI}1;${mod}${arrow}`;
    }
    return `${CSI}${arrow}`;
  }

  const named = NAMED_KEYS[e.key];
  if (named) {
    if (e.key === "Enter" && e.altKey) return `\x1b\r`;
    if (e.key === "Backspace" && e.altKey) return `\x1b\x7f`;
    if (e.key === "Backspace" && e.ctrlKey) return "\x08";
    return named;
  }

  if (e.key.length === 1) {
    const ch = e.key;
    if (e.ctrlKey) {
      const upper = ch.toUpperCase();
      const codePoint = upper.codePointAt(0) ?? 0;
      if (codePoint >= 0x40 && codePoint <= 0x5f) {
        const ctrl = String.fromCharCode(codePoint - 0x40);
        return e.altKey ? `\x1b${ctrl}` : ctrl;
      }
      if (ch === " ") return "\x00";
      return null;
    }
    return e.altKey ? `\x1b${ch}` : ch;
  }
  return null;
}
