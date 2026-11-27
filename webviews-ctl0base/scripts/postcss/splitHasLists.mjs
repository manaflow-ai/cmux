// HAS-LIST: a rule whose selector list holds a `:has(...)` is written as one rule per selector.
//
// Vite's minifier (Lightning CSS) builds for targets that include a browser without `:has` (its
// default cssTarget names Firefox 114), so it keeps such a list from being dropped whole by wrapping
// it in a forgiving `:is(...)`: `A:has(:focus-visible) .x, .x:focus-visible` ships as
// `:is(A:has(:focus-visible) .x, .x:focus-visible)`. WebKit (the app's web view) cannot scope the
// invalidation of a `:has` inside that `:is`, and restyled the pane on every key typed in the
// composer: keydown to keypress 2.8 ms instead of 0.5 (motion.css `.ui-reveal-host:has(:focus-visible)
// .ui-reveal`, bench composer-typing WebKit L0). One rule per selector is the same cascade (each
// selector keeps its own specificity, the rules stay in order) and Lightning CSS leaves a single
// selector alone and does not merge it back with a sibling it would have to wrap.
//
// Detector: test/split-has-lists.test.ts builds every stylesheet under src/ through this config and
// Lightning CSS at Vite's targets and fails on any rule that ships as a whole-list `:is(...)` with a
// `:has(` in it. Pattern: cmuxterm-hq docs/handbook/patterns/webkit-has-invalidation.md.

/** The selectors of `rule` to write one rule each, or undefined to leave it as it is. */
export function hasListParts(rule) {
  const selectors = rule.selectors;
  if (selectors.length < 2 || !selectors.some((one) => one.includes(":has("))) return undefined;
  // A rule with nested rules would copy them once per selector; none in webviews today, and the
  // detector names one if it appears.
  if (rule.nodes?.some((node) => node.type === "rule" || node.type === "atrule")) return undefined;
  return selectors;
}

export default function splitHasLists() {
  return {
    postcssPlugin: "cmux-split-has-lists",
    // After every other plugin's Rule pass (the focus-ring gate can turn one selector into a list).
    OnceExit(root) {
      root.walkRules((rule) => {
        const parts = hasListParts(rule);
        if (!parts) return;
        for (const selector of parts) rule.before(rule.clone({ selector }));
        rule.remove();
      });
    },
  };
}
splitHasLists.postcss = true;
