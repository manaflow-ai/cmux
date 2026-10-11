// TeX in agent replies, typeset by KaTeX: fractions, scripts, roots, matrices, `aligned`
// and the other environments a reply writes. The output is KaTeX's HTML with MathML beside
// it for VoiceOver; its stylesheet and fonts ship with the pane (build-agent-pane-web.sh
// inlines them as data URLs, so the page's CSP needs no font source). `trust` stays off, so
// a reply's TeX cannot draw links, classes, styles or HTML. TeX that does not parse draws
// as its source, as written.
import katex from "katex";

const CACHE_LIMIT = 500;
/// Typeset TeX by mode and source. A transcript draws the same expressions again on every
/// render of a streaming reply and on scroll; KaTeX runs once per expression.
const cache = new Map<string, string | null>();

/** KaTeX HTML for `tex`, or null when it does not parse. */
export function typesetTeX(tex: string, display: boolean): string | null {
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
  const html = typesetTeX(tex, true);
  if (html === null) return <pre className="cv-math-display cv-math-source">{`$$\n${tex}\n$$`}</pre>;
  return <div className="cv-math-display" data-tex={tex} dangerouslySetInnerHTML={{ __html: html }} />;
}
