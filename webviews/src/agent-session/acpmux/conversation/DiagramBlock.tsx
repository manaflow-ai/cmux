// Charts and diagrams in replies: a finished ```vega-lite or ```vega fence with a JSON spec, or a
// finished ```mermaid fence, draws as SVG with the markdown page's renderers
// (pages/markdown/diagrams.ts) and the markdown viewer's bundled libraries, which the pane's scheme
// handler serves as same-origin scripts (`__lib/vega.js`, `__lib/ondine.js`, `__lib/mermaid.js`).
// Vega runs with its AST interpreter (no eval); Mermaid draws with Ondine (WebAssembly, no imports),
// Mermaid 11 as fallback, and the SVG is cleaned before it is shown. The block draws once it nears the
// viewport; Code shows the source. A source the renderer refuses shows the source and why.
import { useEffect, useRef, useState, type ReactNode } from "react";
import { DiagramLibraries, renderMermaid, renderVega } from "../../../pages/markdown/diagrams";
import { useT } from "../i18n";
import { useNearViewport } from "../useNearViewport";
import { CodeBlock } from "./CodeBlock";

const CHART_LANGUAGES = new Set(["vega-lite", "vega"]);

/// Whether a finished fence draws as a chart or diagram: mermaid with source, or a chart language
/// and a JSON object spec.
export function isChart(lang: string, code: string): boolean {
  if (lang.toLowerCase() === "mermaid") return code.trim() !== "";
  if (!CHART_LANGUAGES.has(lang.toLowerCase())) return false;
  try {
    const spec: unknown = JSON.parse(code);
    return typeof spec === "object" && spec !== null && !Array.isArray(spec);
  } catch {
    return false;
  }
}

const libraries = new DiagramLibraries((name) => new URL(`__lib/${name}.js`, document.baseURI).href);

export function DiagramBlock({ lang, code, actions }: { lang: string; code: string; actions?: ReactNode }) {
  const t = useT();
  const [frame, setFrame] = useState<HTMLDivElement | null>(null);
  const near = useNearViewport(frame);
  const chart = useRef<HTMLDivElement>(null);
  const [showCode, setShowCode] = useState(false);
  const [failure, setFailure] = useState<string>();
  const language = lang.toLowerCase();
  const mode = language === "mermaid" ? "mermaid" : language === "vega" ? "vega" : "vega-lite";

  useEffect(() => {
    const target = chart.current;
    if (!near || !target) return;
    let live = true;
    setFailure(undefined);
    const drawn =
      mode === "mermaid" ? renderMermaid(libraries, code, target) : renderVega(libraries, mode, code, target);
    drawn.catch((error: unknown) => {
      if (live) setFailure(error instanceof Error ? error.message : String(error));
    });
    return () => {
      live = false;
    };
  }, [near, mode, code]);

  return (
    <div className="cv-diagram" data-language={mode} ref={setFrame}>
      <div className="cv-diagram__bar">
        <span className="cv-diagram__lang">{mode}</span>
        {!failure && (
          <button type="button" className="cv-diagram__toggle" onClick={() => setShowCode((shown) => !shown)}>
            {showCode ? t("diagram.chart") : t("diagram.code")}
          </button>
        )}
        {actions}
      </div>
      {failure && <div className="cv-diagram__error">{t("diagram.failed", { reason: failure })}</div>}
      <div ref={chart} className="cv-diagram__chart" hidden={showCode || Boolean(failure)} />
      {(showCode || failure) && <CodeBlock code={code} lang={mode === "mermaid" ? "mermaid" : "json"} />}
    </div>
  );
}
