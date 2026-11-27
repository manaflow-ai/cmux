// The one key hint: how every shortcut in the web UI is drawn (tooltips, menus, the command palette,
// buttons, cards). Leo 2026-11-22, on a tooltip's "^⌘M" plate: "such a bullshit long hover and a
// bullshit looking fucking command icon. the fuck are we styling our key input hints as? fucking go
// pick the best and centralize our shit."
//
// The look is macOS's menu shortcut column: the keys as plain text in the host's secondary ink, the
// UI font at the caption size and regular weight, no plate (keyHint.css; the looks considered are in
// the gallery, `ui.key-hint`). The legends are keycapLegend's: modifiers as glyphs (⌃ ⌥ ⇧ ⌘), named
// keys as the word on the key (return, tab, esc, delete), a chord as "⌘J then S".
//
// React draws it with <KeyHint> (KeyHint.tsx); DOM code (ui/titleTooltips.ts, the UI pointer overlay)
// with keyHintElement. Both make the same markup from keyHintStrokes, so the two paths cannot drift:
//
//   <kbd class="ui-key-hint" data-keys="⌃⌘M"><span class="ui-key-hint-key">⌃</span>…</kbd>
//
// scripts/check-key-hints.ts refuses a <kbd>, a keycap class or a run of modifier glyphs drawn
// anywhere else.
import "./keyHint.css";
import { KEYCAP_MODIFIERS, KEYCAP_THEN, keycapKeys, keycapStrokes } from "./keycapLegend";

/** A shortcut as a call site has it: one combined string ("⌃⌘M", "⌘↩", "Esc") or the keycaps array
 * native sends, one entry per key (["⌘", "J", "S"] is the chord ⌘J then S). */
export type KeyHintKeys = string | readonly string[];

/** The class of the hint's root; a host places it, never restyles it. */
export const KEY_HINT_CLASS = "ui-key-hint";

/** The shortcut split into strokes, each a list of its keys' legends: "⌘↩" is [["⌘", "return"]],
 * ["⌘", "J", "S"] is [["⌘", "J"], ["S"]]. */
export function keyHintStrokes(keys: KeyHintKeys): string[][] {
  if (typeof keys === "string") {
    const stroke = keycapKeys(keys);
    return stroke.length ? [stroke] : [];
  }
  return keycapStrokes(keys);
}

/** The raw shortcut, for `data-keys` (what a native host or a test reads back). */
export function keyHintSource(keys: KeyHintKeys): string {
  return typeof keys === "string" ? keys : keys.join("");
}

/** A key's legend is a word ("return", "esc") rather than a glyph or a letter: it gets a space before it. */
export function keyHintIsWord(key: string): boolean {
  return key.length > 1 && !(KEYCAP_MODIFIERS as readonly string[]).includes(key) && /\p{L}{2}/u.test(key);
}

/** The pieces in order, as both renderers draw them. */
export type KeyHintPart = { kind: "key"; text: string; word: boolean } | { kind: "then"; text: string };

export function keyHintParts(keys: KeyHintKeys): KeyHintPart[] {
  const parts: KeyHintPart[] = [];
  keyHintStrokes(keys).forEach((stroke, index) => {
    if (index > 0) parts.push({ kind: "then", text: KEYCAP_THEN });
    for (const key of stroke) parts.push({ kind: "key", text: key, word: keyHintIsWord(key) });
  });
  return parts;
}

/** The hint as DOM, for code that builds nodes by hand (the title tooltips). Same markup and class as
 * <KeyHint>. */
export function keyHintElement(doc: Document, keys: KeyHintKeys, className?: string): HTMLElement {
  const root = doc.createElement("kbd");
  root.className = className ? `${KEY_HINT_CLASS} ${className}` : KEY_HINT_CLASS;
  root.setAttribute("data-keys", keyHintSource(keys));
  for (const part of keyHintParts(keys)) {
    const node = doc.createElement("span");
    if (part.kind === "then") node.className = "ui-key-hint-then";
    else {
      node.className = "ui-key-hint-key";
      if (part.word) node.setAttribute("data-word", "");
    }
    node.textContent = part.text;
    root.append(node);
  }
  return root;
}
