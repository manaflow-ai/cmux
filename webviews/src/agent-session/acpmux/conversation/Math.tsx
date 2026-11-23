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
import { type KaTeX, typesetTeX } from "./mathModel";

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
