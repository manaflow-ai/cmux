// FOCUS-RING (src/ui/focusModality.ts): every `:focus-visible` in a webviews stylesheet also asks
// whether the keyboard earned the ring. The build appends FOCUS_RING_GATE after each one, so a rule
// draws its ring only while the page's root is not `data-focus-modality="pointer"`: a click, a
// shortcut, code, Escape, a scroll or a pointer move takes every ring away together, and a new rule
// gets the same answer without knowing about it. Inside `:not(...)` and `:has(...)` the gated form
// keeps its meaning (`:focus:not(:focus-visible)` is "focused, ring not earned"); out of `:has(...)`
// it goes after the `:has(...)` (see gateFocusVisible).
//
// The text must match FOCUS_RING_GATE in src/ui/focusModality.ts (test/focus-modality.test.ts).
export const FOCUS_RING_GATE = ':where(:not(:root[data-focus-modality="pointer"] *))';

/** Returns `selector` with the gate after every `:focus-visible`, or after the `:has(...)` that holds
 * it, or on the subject when it is left of a sibling combinator (see gateSiblingLeft); already gated
 * selectors stay. Each selector of a list is gated on its own. */
export function gateFocusVisible(selector) {
  if (!selector.includes(":focus-visible") || selector.includes(FOCUS_RING_GATE)) return selector;
  return splitTopLevel(selector, ",")
    .map((one) => gateSiblingLeft(one) ?? gateInPlace(one))
    .join(", ");
}

/** A `:focus-visible` left of a `+` or `~` gets its gate on the subject instead. Left of a sibling
 * combinator, an `:is()` or `:where()` whose branch names no class, id or attribute (the gate is one,
 * `:where(:not(:root[...] *))`) makes Chromium treat that part as any element: each node inserted
 * anywhere in the page then restyled its later siblings and searched their subtrees for the subject.
 * While a reply streamed, the one rule of that shape (suggestedTasks.css, the agent tag's chevron)
 * cost 25-40% of the chat page's style time (Chromium style invalidation trace, 2026-11-17). The gate
 * is a condition on the page's root, so on the subject it means the same. A `:focus-visible` inside a
 * functional pseudo-class on the left (`:is(:hover, :focus-visible)`, `:not(...)`) stays in place:
 * that `:is()` has the same cost, so css-invalidation-scope.test.ts refuses it; write one selector per
 * state instead. Returns undefined when it does not apply. */
function gateSiblingLeft(selector) {
  const cut = lastSiblingCombinator(selector);
  if (cut < 0) return undefined;
  const left = selector.slice(0, cut).trimEnd();
  const spots = focusVisibleSpots(left);
  if (!spots.length || spots.some((spot) => spot.names.some((name) => name !== "has"))) return undefined;
  // The right side (from the combinator on) gated as before; gateInPlace may list it twice.
  return splitTopLevel(gateInPlace(selector.slice(cut)), ",")
    .map((right) => withSubjectGate(`${left} ${right}`))
    .join(", ");
}

/** `selector` with the gate at the end of its subject, before a pseudo-element. */
function withSubjectGate(selector) {
  const pseudo = /::[\w-]+(\([^()]*\))?$/.exec(selector);
  const at = pseudo ? pseudo.index : selector.length;
  if (selector.slice(0, at).endsWith(FOCUS_RING_GATE)) return selector;
  return selector.slice(0, at) + FOCUS_RING_GATE + selector.slice(at);
}

/** Each `:focus-visible` in `text`: its index and the functional pseudo-classes open around it. */
function focusVisibleSpots(text) {
  const spots = [];
  const names = [];
  scanTopLevel(
    text,
    (c, i) => {
      if (c === "(") names.push(/:([\w-]+)$/.exec(text.slice(0, i))?.[1] ?? "");
      else if (c === ")") names.pop();
      else if (text.startsWith(":focus-visible", i) && !/[\w-]/.test(text[i + 14] ?? ""))
        spots.push({ at: i, names: [...names] });
    },
    true,
  );
  return spots;
}

/** Index of the last `+` or `~` combinator outside parentheses, brackets and strings, or -1. */
function lastSiblingCombinator(selector) {
  let cut = -1;
  scanTopLevel(selector, (c, i, depth) => {
    if (!depth && (c === "+" || c === "~")) cut = i;
  });
  return cut;
}

/** Splits at `separator` outside parentheses, brackets and strings; keeps the text as written. */
function splitTopLevel(selector, separator) {
  const parts = [];
  let from = 0;
  scanTopLevel(selector, (c, i, depth) => {
    if (!depth && c === separator) {
      parts.push(selector.slice(from, i).trim());
      from = i + 1;
    }
  });
  parts.push(selector.slice(from).trim());
  return parts;
}

/** Calls `visit(char, index, depth)` for each character outside strings and brackets; with `all`,
 * also inside parentheses (depth counts them). */
function scanTopLevel(text, visit, all = false) {
  let quote = "";
  let bracket = 0;
  let depth = 0;
  for (let i = 0; i < text.length; i += 1) {
    const c = text[i];
    if (quote) {
      if (c === "\\") i += 1;
      else if (c === quote) quote = "";
    } else if (c === '"' || c === "'") quote = c;
    else if (c === "\\") i += 1;
    else if (c === "[") bracket += 1;
    else if (c === "]") bracket -= 1;
    else if (bracket) continue;
    else if (c === "(") {
      if (all) visit(c, i, depth);
      depth += 1;
    } else if (c === ")") {
      depth -= 1;
      if (all) visit(c, i, depth);
    } else if (all || !depth) visit(c, i, depth);
  }
}

/** One selector with the gate after every `:focus-visible`, or after the `:has(...)` that holds it.
 *
 * Where the gate goes matters in WebKit (the app's web view): it does not restyle an element whose
 * `:has(...)` holds the gate when the root attribute flips, so `.box:has(:focus-visible GATE)`
 * kept the composer's rim at rest after a Tab until the next focus change. The gate is a page-wide
 * condition, so it goes right after the outermost `:has(...)` instead (`.box:has(:focus-visible)GATE`),
 * which WebKit restyles like any root-attribute rule and which leaves the alternatives of an
 * enclosing `:is(:hover, ...)` alone. Inside `:not(...)` it stays next to its `:focus-visible`,
 * where `:focus:not(:focus-visible)` keeps meaning "focused, ring not earned".
 *
 * A `:focus-visible` that shares an `:is()` or `:where()` with other alternatives inside the
 * `:has(...)` (`:has(.grip:is(:hover, :focus-visible))`) would take its hover branch down with the
 * gate, so the selector is listed twice: once with that `:focus-visible` never matching (`:not(*)`,
 * the other alternatives as they were, ungated) and once gated. */
function gateInPlace(selector) {
  if (!selector.includes(":focus-visible")) return selector;
  const after = new Set();
  // Positions of the hoisted `:focus-visible`s that share an `:is()`/`:where()` with other
  // alternatives, which the ungated copy replaces with `:not(*)`.
  const shared = [];
  // Gates after a `:has(...)` whose every `:focus-visible` is shared: the ungated copy leaves them out.
  const sharedOnly = new Set();
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
    else if (c === "(")
      stack.push({ name: /:([\w-]+)$/.exec(selector.slice(0, i))?.[1] ?? "", gate: false, own: false });
    else if (c === ")") {
      const open = stack.pop();
      if (open?.gate) {
        after.add(i + 1);
        if (!open.own) sharedOnly.add(i + 1);
      }
    } else if (selector.startsWith(":focus-visible", i) && !/[\w-]/.test(selector[i + 14] ?? "")) {
      const names = stack.map((open) => open.name);
      const has = names.indexOf("has");
      if (has >= 0 && !names.slice(0, has).includes("not")) {
        stack[has].gate = true;
        if (names.slice(has + 1).some((name) => ["is", "where", "matches"].includes(name))) shared.push(i);
        else stack[has].own = true;
      } else after.add(i + 14);
    }
  }
  let out = "";
  for (let i = 0; i <= selector.length; i += 1) {
    if (after.has(i)) out += FOCUS_RING_GATE;
    out += selector[i] ?? "";
  }
  if (!shared.length) return out;
  // The ungated copy: each shared `:focus-visible` never matches; every other one gated as above.
  let other = "";
  for (let i = 0; i <= selector.length; i += 1) {
    if (shared.includes(i)) {
      other += ":not(*)";
      i += 13;
      continue;
    }
    if (after.has(i) && !sharedOnly.has(i)) other += FOCUS_RING_GATE;
    other += selector[i] ?? "";
  }
  return `${other}, ${out}`;
}

/** Declarations that show or hide a control rather than draw its ring: they follow real keyboard
 * focus, ungated, so taking the ring away never hides the control that has focus (a hover-revealed
 * close button, a model's star, a row's actions) while the keyboard is still on it. */
const REVEAL = new Set([
  "visibility",
  "opacity",
  "display",
  "pointer-events",
  "width",
  "max-width",
  "min-width",
  "height",
  "max-height",
  "min-height",
  "overflow",
  "clip-path",
  "transform",
  "translate",
  "scale",
  "z-index",
]);

export default function focusRingGate() {
  return {
    postcssPlugin: "cmux-focus-ring-gate",
    Rule(rule) {
      const gated = gateFocusVisible(rule.selector);
      if (gated === rule.selector) return;
      // A pseudo-element (a dot, a hat's wings) is drawing, never a control the keyboard needs: all
      // of its rule is the ring's.
      const drawsOnly = /::?(before|after|marker|backdrop)\b/.test(rule.selector);
      const reveal = drawsOnly
        ? []
        : rule.nodes.filter((node) => node.type === "decl" && REVEAL.has(node.prop.toLowerCase()));
      // Only reveal declarations: the rule shows a control, it draws no ring.
      if (reveal.length === rule.nodes.length) return;
      // A mix: the reveal half stays on real focus, the rest is gated.
      if (reveal.length) {
        const shown = rule.clone({ nodes: [] });
        for (const node of reveal) shown.append(node.clone());
        rule.before(shown);
        for (const node of reveal) node.remove();
      }
      rule.selector = gated;
    },
  };
}
focusRingGate.postcss = true;
