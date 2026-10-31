// Charts and diagrams in replies: a finished ```vega-lite or ```vega fence with a JSON spec, or a
// finished ```mermaid fence, draws as SVG with the markdown page's renderers
// (pages/markdown/diagrams.ts) and the markdown viewer's bundled libraries, which the pane's scheme
// handler serves as same-origin scripts (`__lib/vega.js`, `__lib/ondine.js`, `__lib/mermaid.js`).
// Vega runs with its AST interpreter (no eval); Mermaid draws with Ondine (WebAssembly, no imports),
// Mermaid 11 as fallback, and the SVG is cleaned before it is shown. The block draws once it nears the
// viewport; Code shows the source. A source the renderer refuses shows the source and why.
import { useEffect, useRef, useState, type ReactNode } from "react";
import { cancelDiagram, DiagramLibraries, renderMermaid, renderVega } from "../../../pages/markdown/diagrams";
import { useT } from "../i18n";
import { useNearViewport } from "../useNearViewport";
import { postNative } from "../native";
import { copyText } from "./clipboard";
import { CodeBlock } from "./CodeBlock";
import { Check, SaveTray } from "./icons";

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
  const [saved, setSaved] = useState(false);
  const [drawn, setDrawn] = useState(false);
  const language = lang.toLowerCase();
  const mode = language === "mermaid" ? "mermaid" : language === "vega" ? "vega" : "vega-lite";

  useEffect(() => {
    const target = chart.current;
    if (!near || !target) return;
    let live = true;
    setFailure(undefined);
    setDrawn(false);
    setSaved(false);
    const drawing =
      mode === "mermaid" ? renderMermaid(libraries, code, target) : renderVega(libraries, mode, code, target);
    drawing.then(
      () => {
        if (live) setDrawn(true);
      },
      (error: unknown) => {
        if (live) setFailure(error instanceof Error ? error.message : String(error));
      },
    );
    return () => {
      live = false;
      // Stops the Vega view and makes a render still running drop its result, so it never replaces the
      // chart a later draw enabled Save for.
      cancelDiagram(target);
    };
  }, [near, mode, code]);

  return (
    <div className="cv-diagram" data-language={mode} ref={setFrame}>
      <div className="cv-diagram__bar">
        <span className="cv-diagram__lang">{mode}</span>
        <span className="cv-diagram__tools">
          {!failure && (
            <button
              type="button"
              className="cv-diagram__toggle"
              data-fold-toggle=""
              onClick={() => setShowCode((shown) => !shown)}
            >
              {showCode ? t("diagram.chart") : t("diagram.code")}
            </button>
          )}
          {drawn && !failure && !showCode && (
            <button
              type="button"
              className="cv-diagram__toggle"
              aria-label={saved ? t("artifact.saved") : t("artifact.save")}
              title={saved ? t("artifact.saved") : t("artifact.save")}
              onClick={() => {
                const svg = chart.current?.querySelector("svg");
                if (!svg) return;
                const text = new XMLSerializer().serializeToString(svg);
                // The host's save panel (`pane.saveFile`, as the side panel's Save); a host that has none, or
                // failed to write, is as good as none: copy the SVG instead.
                void postNative<boolean>("pane.saveFile", { text, suggestedName: mode, kind: "svg" })
                  .then((done) => setSaved(done === true))
                  .catch(() => void copyText(text));
              }}
            >
              {saved ? <Check size={14} /> : <SaveTray size={14} />}
            </button>
          )}
        </span>
        {actions}
      </div>
      {failure && <div className="cv-diagram__error">{t("diagram.failed", { reason: failure })}</div>}
      <div ref={chart} className="cv-diagram__chart" hidden={showCode || Boolean(failure)} />
      {(showCode || failure) && <CodeBlock code={code} lang={mode === "mermaid" ? "mermaid" : "json"} />}
    </div>
  );
}
