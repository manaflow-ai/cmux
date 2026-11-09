// FOCUS-RING (src/ui/focusModality.ts): every `:focus-visible` in a webviews stylesheet also asks
// whether the keyboard earned the ring. The build appends FOCUS_RING_GATE after each one, so a rule
// draws its ring only while the page's root is not `data-focus-modality="pointer"`: a click, a
// shortcut, code, Escape, a scroll or a pointer move takes every ring away together, and a new rule
// gets the same answer without knowing about it. Inside `:not(...)` and `:has(...)` the gated form
// keeps its meaning (`:focus:not(:focus-visible)` is "focused, ring not earned").
//
// The text must match FOCUS_RING_GATE in src/ui/focusModality.ts (test/focus-modality.test.ts).
export const FOCUS_RING_GATE = ':not(:root[data-focus-modality="pointer"] *)';

const FOCUS_VISIBLE = /:focus-visible(?![\w-])/g;

/** Returns `selector` with the gate after every `:focus-visible`; already gated selectors stay. */
export function gateFocusVisible(selector) {
  if (!selector.includes(":focus-visible") || selector.includes(FOCUS_RING_GATE)) return selector;
  return selector.replace(FOCUS_VISIBLE, `:focus-visible${FOCUS_RING_GATE}`);
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
