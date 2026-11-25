// Charts and diagrams in replies: a finished ```vega-lite or ```vega fence with a JSON spec, or a
// finished ```mermaid fence, draws as SVG with the markdown page's renderers
// (pages/markdown/diagrams.ts) and the markdown viewer's bundled libraries, which the pane's scheme
// handler and the page host (AgentPageResources) serve as same-origin scripts (`__lib/vega.js`,
// `__lib/ondine.js`, `__lib/mermaid.js`).
// Vega runs with its AST interpreter (no eval); Mermaid draws with Ondine (WebAssembly, no imports),
// Mermaid 11 as fallback, and the SVG is cleaned before it is shown. The block draws once it nears the
// viewport; Code shows the source. A source the renderer refuses shows the source and why; a renderer
// that did not load says so in plain words (never its internal name) above the source. A ```chart
// fence (small JSON, chartSpec.ts) compiles to a Vega-Lite spec and draws the same way; Code shows what
// the agent wrote.
import { useEffect, useMemo, useRef, useState, type CSSProperties, type ReactNode } from "react";
import {
  cancelDiagram,
  DiagramLibraries,
  DiagramLoadError,
  renderMermaid,
  renderVega,
} from "../../../pages/markdown/diagrams";
import { useT } from "../i18n";
import { useViewportReach } from "../useNearViewport";
import { postNative } from "../native";
import { copyText } from "./clipboard";
import { chartSpec } from "./chartSpec";
import { CodeBlock } from "./CodeBlock";
import { Check, SaveTray } from "./icons";
import { useUnsettledHeight } from "./unsettledHeights";
const libraries = new DiagramLibraries((name) => new URL(`__lib/${name}.js`, document.baseURI).href);

export function DiagramBlock({ lang, code, actions }: { lang: string; code: string; actions?: ReactNode }) {
  const t = useT();
  const [frame, setFrame] = useState<HTMLDivElement | null>(null);
  const reach = useViewportReach(frame);
  const near = reach === "near";
  const chart = useRef<HTMLDivElement>(null);
  const [showCode, setShowCode] = useState(false);
  // Why the chart did not draw: the source's reason, or null when a renderer did not load.
  const [failure, setFailure] = useState<{ reason: string | null }>();
  const [saved, setSaved] = useState(false);
  const [drawn, setDrawn] = useState(false);
  const language = lang.toLowerCase();
  const mode = language === "mermaid" ? "mermaid" : language === "vega" ? "vega" : "vega-lite";
  const label = language === "chart" ? "chart" : mode;
  const spec = useMemo(() => (language === "chart" ? (chartSpec(code) ?? code) : code), [language, code]);
  const reserve = useMemo(() => (mode === "mermaid" ? undefined : chartBox(spec)), [mode, spec]);
  // Until it is drawn (or refused) a chart with no reserved box (a Mermaid diagram, a chart whose
  // size its spec does not give) is not at its height: an opening chat waits for it
  // (unsettledHeights.ts), while it is near enough to draw. One a screen or more away (or in a hidden
  // pane) draws only once the reader comes near it, so nothing waits on it.
  useUnsettledHeight(!reserve && reach !== "far" && !drawn && !failure && !showCode);

  useEffect(() => {
    const target = chart.current;
    if (!near || !target) return;
    let live = true;
    setFailure(undefined);
    setDrawn(false);
    setSaved(false);
    const drawing =
      mode === "mermaid" ? renderMermaid(libraries, spec, target) : renderVega(libraries, mode, spec, target);
    drawing.then(
      () => {
        if (live) setDrawn(true);
      },
      (error: unknown) => {
        if (!live) return;
        // A renderer that did not load is the app's fault, not the source's: plain words, no library name.
        if (error instanceof DiagramLoadError) setFailure({ reason: null });
        else setFailure({ reason: error instanceof Error ? error.message : String(error) });
      },
    );
    return () => {
      live = false;
      // Stops the Vega view and makes a render still running drop its result, so it never replaces the
      // chart a later draw enabled Save for.
      cancelDiagram(target);
    };
  }, [near, mode, spec]);

  return (
    <div className="cv-diagram" data-language={label} ref={setFrame}>
      <div className="cv-diagram__bar">
        <span className="cv-diagram__lang">{label}</span>
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
      {failure && (
        <div className="cv-diagram__error">
          {failure.reason === null ? t("diagram.unavailable") : t("diagram.failed", { reason: failure.reason })}
        </div>
      )}
      <div
        ref={chart}
        className="cv-diagram__chart"
        hidden={showCode || Boolean(failure)}
        data-reserve={reserve ? "" : undefined}
        style={
          reserve
            ? ({
                "--cv-diagram-w": `${reserve.width}px`,
                "--cv-diagram-ratio": `${reserve.width} / ${reserve.height}`,
              } as CSSProperties)
            : undefined
        }
      />
      {(showCode || failure) && <CodeBlock code={code} lang={mode === "mermaid" ? "mermaid" : "json"} />}
    </div>
  );
}

/// The axes, labels and padding Vega draws around a spec's plot (px): the box a chart is drawn in is
/// about its plot plus this, so the frame keeps that box from the first frame and the chart draws
/// into it (the library loads and draws after the reply is on screen).
const CHART_FRAME = { width: 56, height: 52 };

/// The box a Vega or Vega-Lite spec with a fixed plot size draws in (its own width and height plus
/// the axes'), or none for a spec that sizes itself (no numbers, "container", a source that is not JSON).
export function chartBox(spec: string): { width: number; height: number } | undefined {
  let parsed: unknown;
  try {
    parsed = JSON.parse(spec);
  } catch {
    return undefined;
  }
  if (!parsed || typeof parsed !== "object") return undefined;
  const { width, height } = parsed as { width?: unknown; height?: unknown };
  if (typeof width !== "number" || typeof height !== "number" || !(width > 0) || !(height > 0)) return undefined;
  return { width: Math.round(width + CHART_FRAME.width), height: Math.round(height + CHART_FRAME.height) };
}
