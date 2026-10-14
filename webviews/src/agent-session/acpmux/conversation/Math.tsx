// TeX in agent replies, typeset by KaTeX: fractions, scripts, roots, matrices, `aligned`
// and the other environments a reply writes. The output is KaTeX's HTML with MathML beside
// it for VoiceOver; it takes the text's color, so it follows the theme. `trust` stays off, so
// a reply's TeX cannot draw links, classes, styles or HTML. TeX that does not parse draws
// as its source, as written. KaTeX, its stylesheet and its fonts load only when a reply first
// draws math: a chat without math never pays for them. Until they arrive (a local chunk, a
// frame or two) the math shows its source. The fonts ship with the pane: the bundle turns the
// stylesheet into a chunk that adds it with the fonts inlined as data URLs (katexStylePlugin.mjs),
// so the page's CSP needs no font source and nothing loads from the network. A selection copies
// each equation as the TeX it was written in (mathCopy.ts).
import { useSyncExternalStore } from "react";
import { installMathCopy } from "./mathCopy";

type KaTeX = typeof import("katex").default;
let katex: KaTeX | null = null;
const listeners = new Set<() => void>();
let loading: Promise<void> | null = null;
function load() {
  loading ??= Promise.all([import("katex"), import("./katexStyle")])
    .then(([module]) => {
      katex = module.default;
      installMathCopy();
      for (const listener of listeners) listener();
    })
    .catch(() => {
      // A chunk that failed to load is fetched again by the next equation drawn.
      loading = null;
    });
}

/** KaTeX once its chunk has run; components drawing math draw again then. */
function useKaTeX(): KaTeX | null {
  return useSyncExternalStore(
    (listener) => {
      load();
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    () => katex,
  );
}

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

/** Inline math; `display` for a `$$…$$` written inside a paragraph, centered on its own line. */
export function MathInline({ tex, display = false }: { tex: string; display?: boolean }) {
  const html = typesetTeX(useKaTeX(), tex, display);
  if (html === null) return <span className="cv-math-source">{display ? `$$${tex}$$` : `$${tex}$`}</span>;
  return (
    <span
      className={display ? "cv-math cv-math--display" : "cv-math"}
      data-tex={tex}
      dangerouslySetInnerHTML={{ __html: html }}
    />
  );
}

/** Display equation: centered, and scrolls sideways when wider than the column. */
export function MathDisplay({ tex }: { tex: string }) {
  const html = typesetTeX(useKaTeX(), tex, true);
  if (html === null) return <pre className="cv-math-display cv-math-source">{`$$\n${tex}\n$$`}</pre>;
  return <div className="cv-math-display" data-tex={tex} dangerouslySetInnerHTML={{ __html: html }} />;
}
