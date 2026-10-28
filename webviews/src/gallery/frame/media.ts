// The window's appearance and accessibility settings for a stage frame. In the app a page's
// `prefers-color-scheme` follows the window's appearance, and `prefers-reduced-motion` and
// `prefers-contrast` follow the system settings; a browser frame reports the browser's own. This
// emulates the three features in the frame, as a test browser's media emulation does (the matrix
// runner also sets them through Playwright): every stylesheet's @media rules that test one of
// them are rewritten to the emulated answer, and window.matchMedia answers the same way.

export type MediaOverrides = {
  "prefers-color-scheme": "dark" | "light";
  "prefers-reduced-motion": "reduce" | "no-preference";
  "prefers-contrast": "more" | "no-preference";
};

const ALWAYS = "(min-width: 0px)";
const NEVER = "(min-resolution: 999999dppx)";
const FEATURE = /\(\s*(prefers-color-scheme|prefers-reduced-motion|prefers-contrast)\s*(?::\s*([a-z-]+)\s*)?\)/g;

/** `query` with each emulated feature test replaced by an always-true or never-true test. */
export function rewriteMediaQuery(query: string, overrides: MediaOverrides): string {
  return query.replace(FEATURE, (_, feature: keyof MediaOverrides, value: string | undefined) => {
    const actual = overrides[feature];
    // A bare `(prefers-reduced-motion)` is true for any value but `no-preference`.
    const matches = value === undefined ? actual !== "no-preference" && actual !== "light" : value === actual;
    return matches ? ALWAYS : NEVER;
  });
}

const rewritten = new WeakSet<CSSRule>();

function rewriteRules(rules: CSSRuleList, overrides: MediaOverrides): void {
  for (const rule of Array.from(rules)) {
    if (rule instanceof CSSMediaRule && !rewritten.has(rule)) {
      const text = rule.media.mediaText;
      const next = rewriteMediaQuery(text, overrides);
      if (next !== text) rule.media.mediaText = next;
      rewritten.add(rule);
    }
    if ("cssRules" in rule && (rule as CSSGroupingRule).cssRules)
      rewriteRules((rule as CSSGroupingRule).cssRules, overrides);
    if (rule instanceof CSSImportRule && rule.styleSheet) rewriteSheet(rule.styleSheet, overrides);
  }
}

function rewriteSheet(sheet: CSSStyleSheet, overrides: MediaOverrides): void {
  try {
    rewriteRules(sheet.cssRules, overrides);
  } catch {
    // A cross-origin sheet has no readable rules; the gallery loads none.
  }
}

export function emulateMedia(overrides: MediaOverrides): void {
  const sweep = () => {
    for (const sheet of Array.from(document.styleSheets)) rewriteSheet(sheet, overrides);
  };
  sweep();
  // Stylesheets arrive as the page loads (Vite's style tags, lazy chunks, hot updates).
  // Only their own CSSOM can have changed. Image loads and unrelated head mutations must not
  // walk every rule again while the product commits its first chat.
  const owners = (node: Node, sheets: Set<CSSStyleSheet>) => {
    const element = node.nodeType === Node.ELEMENT_NODE ? (node as Element) : node.parentElement;
    const owner = element?.closest("style, link[rel~='stylesheet']") as HTMLStyleElement | HTMLLinkElement | null;
    if (owner?.sheet) sheets.add(owner.sheet);
    // A head comment or whitespace has no descendant owners of its own.
    if (node.nodeType !== Node.ELEMENT_NODE) return;
    for (const child of element?.querySelectorAll<HTMLStyleElement | HTMLLinkElement>(
      "style, link[rel~='stylesheet']",
    ) ?? [])
      if (child.sheet) sheets.add(child.sheet);
  };
  new MutationObserver((mutations) => {
    const sheets = new Set<CSSStyleSheet>();
    for (const mutation of mutations) {
      // The target is the existing style when Vite replaces its text.
      const target = mutation.target;
      if (target.nodeType === Node.TEXT_NODE || (target as Element).matches?.("style")) owners(target, sheets);
      for (const added of mutation.addedNodes) owners(added, sheets);
    }
    for (const sheet of sheets) rewriteSheet(sheet, overrides);
  }).observe(document.head, { subtree: true, childList: true, characterData: true });
  document.addEventListener(
    "load",
    (event) => {
      // Inline @import rules may finish after the style mutation was processed.
      const owner = event.target as HTMLStyleElement | HTMLLinkElement | null;
      if (owner?.matches?.("style, link[rel~='stylesheet']") && owner.sheet) rewriteSheet(owner.sheet, overrides);
    },
    true,
  );
  const realMatchMedia = window.matchMedia.bind(window);
  window.matchMedia = (query: string) => {
    const next = rewriteMediaQuery(query, overrides);
    if (next === query) return realMatchMedia(query);
    const list = realMatchMedia(next);
    return new Proxy(list, {
      get: (target, key) => {
        if (key === "media") return query;
        const value = Reflect.get(target, key, target);
        return typeof value === "function" ? value.bind(target) : value;
      },
    });
  };
}
