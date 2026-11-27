export type KaTeX = typeof import("katex").default;
const CACHE_LIMIT = 500;
/// Typeset TeX by mode and source. A transcript draws the same expressions again on every
/// render of a streaming reply and on scroll; KaTeX runs once per expression.
const cache = new Map<string, string | null>();

/**
 * KaTeX HTML for `tex`, or null when it does not parse or KaTeX (`loaded`, from useKaTeX) has not
 * loaded. KaTeX is an argument, not read from the module, so a memoized call (the React Compiler
 * caches it by its inputs) runs again when KaTeX arrives.
 */
export function typesetTeX(loaded: KaTeX | null, tex: string, display: boolean): string | null {
  if (!loaded) return null;
  const key = `${display ? "D" : "I"}${tex}`;
  const hit = cache.get(key);
  if (hit !== undefined) return hit;
  let html: string | null;
  try {
    html = loaded.renderToString(tex, {
      displayMode: display,
      output: "htmlAndMathml",
      throwOnError: true,
      strict: "ignore",
      trust: false,
      // A reply cannot make a huge box or expand macros forever.
      maxSize: 50,
      maxExpand: 500,
    });
  } catch {
    html = null;
  }
  if (cache.size >= CACHE_LIMIT) cache.delete(cache.keys().next().value!);
  cache.set(key, html);
  return html;
}
