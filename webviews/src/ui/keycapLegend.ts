// What a key drawn on a keycap plate says, as a Mac keyboard prints it (Leo 2026-11-22: "this
// command palette's icons are really bad and not even properly depicting the keys"): modifiers stay
// glyphs (⌘ ⌥ ⌃ ⇧), named keys are the lowercase words on the key (return, tab, esc, delete, space),
// anything else (letters, digits, arrows) as given. Every plated keycap goes through here, so a call
// site can pass "↩" or "⌘↩" and the cap reads "return" or "⌘ return". Plain menu-hint text keeps the
// macOS menu glyphs (⌘↩) and does not use this.

/** The modifier glyphs, in the order macOS writes them. */
export const KEYCAP_MODIFIERS = ["⌃", "⌥", "⇧", "⌘"] as const;

/** The word drawn between the two strokes of a chord (⌘J then S), as plain text, not a cap. */
export const KEYCAP_THEN = "then";

const NAMED: Record<string, string> = {
  "↩": "return",
  "↵": "return",
  "⏎": "return",
  "⌤": "return",
  return: "return",
  enter: "return",
  "⇥": "tab",
  tab: "tab",
  "⎋": "esc",
  esc: "esc",
  escape: "esc",
  "⌫": "delete",
  delete: "delete",
  backspace: "delete",
  "␣": "space",
  space: "space",
};

function isModifier(key: string): boolean {
  return (KEYCAP_MODIFIERS as readonly string[]).includes(key);
}

/** One key's legend: "↩" and "Enter" read "return", "⎋" and "Esc" read "esc", "⌘" stays "⌘". */
function namedLegend(key: string): string | undefined {
  return NAMED[key] ?? NAMED[key.toLowerCase()];
}

/** A combined key string split into one entry per key, each as its cap reads: "⌘↩" is
 * ["⌘", "return"], "⌥⌘2" is ["⌥", "⌘", "2"], "Esc" is ["esc"]. */
export function keycapKeys(combo: string): string[] {
  const keys: string[] = [];
  let rest = combo.trim();
  while (rest.length > 0) {
    const head = rest.charAt(0);
    if (!isModifier(head)) break;
    keys.push(head);
    rest = rest.slice(1).trimStart();
  }
  if (rest.length > 0) keys.push(namedLegend(rest) ?? rest);
  return keys;
}

/** A key, or a combined key string, as one plate reads it: "↩" is "return", "⌘↩" is "⌘ return",
 * "⌘D" stays "⌘D" (a word gets a space after the modifiers, a glyph or letter does not). */
export function keycapLegend(key: string): string {
  const keys = keycapKeys(key);
  const last = keys[keys.length - 1];
  if (!last || keys.length === 1) return last ?? key;
  const word = last.length > 1 && !isModifier(last);
  return word ? `${keys.slice(0, -1).join("")} ${last}` : keys.join("");
}

/** A keycaps array (one entry per key, as native sends) split into its strokes: a stroke ends at
 * its first key that is not a modifier, so ["⌘", "J", "S"] is [["⌘", "J"], ["S"]], drawn as
 * ⌘ J, then, S. Each key is its cap's legend. */
export function keycapStrokes(caps: readonly string[]): string[][] {
  const strokes: string[][] = [];
  let stroke: string[] = [];
  for (const cap of caps) {
    stroke.push(isModifier(cap) ? cap : keycapLegend(cap));
    if (!isModifier(cap)) {
      strokes.push(stroke);
      stroke = [];
    }
  }
  if (stroke.length > 0) strokes.push(stroke);
  return strokes;
}
