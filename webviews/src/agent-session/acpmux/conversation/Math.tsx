// TeX in agent replies, typeset by KaTeX: fractions, scripts, roots, matrices, `aligned`
// and the other environments a reply writes. The output is KaTeX's HTML with MathML beside
// it for VoiceOver; its stylesheet and fonts ship with the pane (build-agent-pane-web.sh
// inlines the fonts as data URLs, so the page's CSP needs no font source) and are applied with
// KaTeX (`loadStyles`). `trust` stays off, so
// a reply's TeX cannot draw links, classes, styles or HTML. TeX that does not parse draws
// as its source, as written. KaTeX is its own chunk: the pane's first frame does not wait to
// parse it, and math drawn before it arrives shows its source until it does.
import { useSyncExternalStore } from "react";

type KaTeX = typeof import("katex").default;
let katex: KaTeX | null = null;
const listeners = new Set<() => void>();
let loading: Promise<void> | null = null;
function load() {
  loading ??= Promise.all([import("katex"), loadStyles()]).then(([module]) => {
    katex = module.default;
    for (const listener of listeners) listener();
  });
}

/// The bundled page's KaTeX sheet, `katex-styles.js` beside index.html: kept out of the page, whose
/// first frame would otherwise parse its fonts (bd cx-z9kz0). The dev server and the gallery import
/// the sheet; there this resolves at once.
function loadStyles(): Promise<void> {
  if (typeof location === "undefined" || (location.protocol !== "cmux-agent:" && location.protocol !== "cmux-page:"))
    return Promise.resolve();
  return new Promise((resolve) => {
    const script = document.createElement("script");
    script.src = new URL("katex-styles.js", location.href).href;
    // Math without its sheet still reads; KaTeX draws it either way.
    script.onload = script.onerror = () => resolve();
    document.head.append(script);
  });
}
// Fetched after the first frame, or sooner by the first math drawn.
if (typeof requestAnimationFrame === "function") requestAnimationFrame(() => setTimeout(load, 0));

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

/** KaTeX HTML for `tex`, or null when it does not parse or KaTeX has not loaded. */
export function typesetTeX(tex: string, display: boolean): string | null {
  if (!katex) return null;
  const key = `${display ? "D" : "I"}${tex}`;
  const hit = cache.get(key);
  if (hit !== undefined) return hit;
  let html: string | null;
  try {
    html = katex.renderToString(tex, {
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
  useKaTeX();
  const html = typesetTeX(tex, display);
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
  useKaTeX();
  const html = typesetTeX(tex, true);
  if (html === null) return <pre className="cv-math-display cv-math-source">{`$$\n${tex}\n$$`}</pre>;
  return <div className="cv-math-display" data-tex={tex} dangerouslySetInnerHTML={{ __html: html }} />;
}
