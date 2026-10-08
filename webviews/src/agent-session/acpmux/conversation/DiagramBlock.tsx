// Charts in replies: a finished ```vega-lite or ```vega fence with a JSON spec draws as an SVG
// chart, with the markdown page's renderer (pages/markdown/diagrams.ts) and the markdown viewer's
// bundled Vega, which the pane's scheme handler serves as the same-origin script `__lib/vega.js`
// (Vega runs with its AST interpreter, no eval). The chart draws once the block nears the
// viewport; Code shows the spec. A spec Vega refuses shows the spec and why.
// Mermaid stays a code block until the shared diagram worker draws it.
import { useEffect, useRef, useState } from "react";
import { DiagramLibraries, renderVega } from "../../../pages/markdown/diagrams";
import { useT } from "../i18n";
import { useNearViewport } from "../useNearViewport";
import { CodeBlock } from "./CodeBlock";

const CHART_LANGUAGES = new Set(["vega-lite", "vega"]);

/// Whether a finished fence draws as a chart: a chart language and a JSON object spec.
export function isChart(lang: string, code: string): boolean {
  if (!CHART_LANGUAGES.has(lang.toLowerCase())) return false;
  try {
    const spec: unknown = JSON.parse(code);
    return typeof spec === "object" && spec !== null && !Array.isArray(spec);
  } catch {
    return false;
  }
}

const libraries = new DiagramLibraries((name) =>
  name === "vega" ? new URL(`__lib/${name}.js`, document.baseURI).href : null,
);

export function DiagramBlock({ lang, code }: { lang: string; code: string }) {
  const t = useT();
  const [frame, setFrame] = useState<HTMLDivElement | null>(null);
  const near = useNearViewport(frame);
  const chart = useRef<HTMLDivElement>(null);
  const [showCode, setShowCode] = useState(false);
  const [failure, setFailure] = useState<string>();
  const mode = lang.toLowerCase() === "vega" ? "vega" : "vega-lite";

  useEffect(() => {
    const target = chart.current;
    if (!near || !target) return;
    let live = true;
    setFailure(undefined);
    renderVega(libraries, mode, code, target).catch((error: unknown) => {
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
      </div>
      {failure && <div className="cv-diagram__error">{t("diagram.failed", { reason: failure })}</div>}
      <div ref={chart} className="cv-diagram__chart" hidden={showCode || Boolean(failure)} />
      {(showCode || failure) && <CodeBlock code={code} lang="json" />}
    </div>
  );
}
