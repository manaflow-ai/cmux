// FOCUS-RING (src/ui/focusModality.ts): every `:focus-visible` in a webviews stylesheet also asks
// whether the keyboard earned the ring. The build appends FOCUS_RING_GATE after each one, so a rule
// draws its ring only while the page's root is not `data-focus-modality="pointer"`: a click, a
// shortcut, code, Escape, a scroll or a pointer move takes every ring away together, and a new rule
// gets the same answer without knowing about it. Inside `:not(...)` and `:has(...)` the gated form
// keeps its meaning (`:focus:not(:focus-visible)` is "focused, ring not earned"); out of `:has(...)`
// it goes after the `:has(...)` (see gateFocusVisible).
//
// The text must match FOCUS_RING_GATE in src/ui/focusModality.ts (test/focus-modality.test.ts).
export const FOCUS_RING_GATE = ':not(:root[data-focus-modality="pointer"] *)';

/** Returns `selector` with the gate after every `:focus-visible`, or after the `:has(...)` that holds
 * it; already gated selectors stay.
 *
 * Where the gate goes matters in WebKit (the app's web view): it does not restyle an element whose
 * `:has(...)` holds the gate when the root attribute flips, so `.box:has(:focus-visible GATE)`
 * kept the composer's rim at rest after a Tab until the next focus change. The gate is a page-wide
 * condition, so it goes right after the outermost `:has(...)` instead (`.box:has(:focus-visible)GATE`),
 * which WebKit restyles like any root-attribute rule and which leaves the alternatives of an
 * enclosing `:is(:hover, ...)` alone. Inside `:not(...)` it stays next to its `:focus-visible`,
 * where `:focus:not(:focus-visible)` keeps meaning "focused, ring not earned". */
export function gateFocusVisible(selector) {
  if (!selector.includes(":focus-visible") || selector.includes(FOCUS_RING_GATE)) return selector;
  const after = new Set();
  // The functional pseudo-classes open around the current position, each with whether a
  // `:focus-visible` inside it is gated at its close.
  const stack = [];
  let quote = "";
  let bracket = 0;
  for (let i = 0; i < selector.length; i += 1) {
    const c = selector[i];
    if (quote) {
      if (c === "\\") i += 1;
      else if (c === quote) quote = "";
    } else if (c === '"' || c === "'") quote = c;
    else if (c === "\\") i += 1;
    else if (c === "[") bracket += 1;
    else if (c === "]") bracket -= 1;
    else if (bracket) continue;
    else if (c === "(") stack.push({ name: /:([\w-]+)$/.exec(selector.slice(0, i))?.[1] ?? "", gate: false });
    else if (c === ")") {
      if (stack.pop()?.gate) after.add(i + 1);
    } else if (selector.startsWith(":focus-visible", i) && !/[\w-]/.test(selector[i + 14] ?? "")) {
      const names = stack.map((open) => open.name);
      const has = names.indexOf("has");
      if (has >= 0 && !names.slice(0, has).includes("not")) stack[has].gate = true;
      else after.add(i + 14);
    }
  }
  let out = "";
  for (let i = 0; i <= selector.length; i += 1) {
    if (after.has(i)) out += FOCUS_RING_GATE;
    out += selector[i] ?? "";
  }
  return out;
}

export default function focusRingGate() {
  return {
    postcssPlugin: "cmux-focus-ring-gate",
    Rule(rule) {
      const gated = gateFocusVisible(rule.selector);
      if (gated !== rule.selector) rule.selector = gated;
    },
  };
}
focusRingGate.postcss = true;
