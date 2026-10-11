// A render card above a turn's answer (renderCall.ts): the agent's HTML, live, in the render frame
// (`cmux-agent://render/frame`, AgentPaneRenderFrame.swift). The frame is an origin of its own,
// sandboxed without same-origin, so the HTML cannot reach the pane, its bridge or acpmux; its
// policy allows no connection. The frame asks for the HTML once it loads and reports its height;
// the card grows to it, up to a cap a reader can lift. Nothing runs until the reader presses Run:
// the frame shares the pane's web process, so a busy loop in agent HTML would freeze the pane. The
// pane on a dev server has no render frame, so there the call stays a plain tool row.
import { useEffect, useRef, useState } from "react";
import { useT } from "../i18n";
import { RENDER_FRAME_MIN_HEIGHT, type RenderCall } from "./renderCall";

export const RENDER_FRAME_URL = "cmux-agent://render/frame";
/// The tallest a card draws until the reader expands it.
const COLLAPSED_MAX_HEIGHT = 560;
/// The tallest an expanded card draws; a taller page scrolls inside it.
const EXPANDED_MAX_HEIGHT = 4000;

/// The HTML the reader has run while this pane lives: a card scrolled away and back keeps
/// running, and a reloaded pane (after a hang or a crash) starts with every card waiting again.
export const ranRenders = new Set<string>();

/// Whether this page can frame renders: only the bundled pane has the render origin.
export const canRender = () => typeof location !== "undefined" && location.protocol === "cmux-agent:";

/// The pane's theme as variables the HTML can use (`var(--cmux-text)`), under its own styles.
function themeCSS(): string {
  const style = getComputedStyle(document.body);
  const read = (name: string, fallback: string) => style.getPropertyValue(name).trim() || fallback;
  const scheme = style.colorScheme.includes("dark") ? "dark" : "light";
  return [
    `:root{color-scheme:${scheme};`,
    `--cmux-text:${read("--agent-text", "CanvasText")};`,
    `--cmux-muted:${read("--agent-muted", "GrayText")};`,
    `--cmux-bg:${read("--agent-page-bg", "Canvas")};`,
    `--cmux-border:${read("--agent-border", "GrayText")};`,
    `--cmux-font:${read("--cv-font", "-apple-system, system-ui, sans-serif")};`,
    `--cmux-mono:${read("--font-mono", "ui-monospace, monospace")}}`,
    "html{background:transparent}",
    "body{margin:0;color:var(--cmux-text);font:13px/1.45 var(--cmux-font)}",
  ].join("");
}

export function RenderCard({ call }: { call: RenderCall }) {
  const t = useT();
  const frame = useRef<HTMLIFrameElement>(null);
  const [height, setHeight] = useState(RENDER_FRAME_MIN_HEIGHT);
  const [expanded, setExpanded] = useState(false);
  const [running, setRunning] = useState(() => ranRenders.has(call.html));
  useEffect(() => {
    const onMessage = (event: MessageEvent) => {
      const target = frame.current?.contentWindow;
      if (!target || event.source !== target) return;
      const data: unknown = event.data;
      if (!data || typeof data !== "object") return;
      const message = data as { type?: unknown; height?: unknown };
      if (message.type === "cmux-render-ready")
        target.postMessage({ type: "cmux-render", html: call.html, css: themeCSS() }, "*");
      else if (
        message.type === "cmux-render-size" &&
        typeof message.height === "number" &&
        Number.isFinite(message.height)
      )
        setHeight(Math.min(EXPANDED_MAX_HEIGHT, Math.max(RENDER_FRAME_MIN_HEIGHT, Math.ceil(message.height))));
    };
    addEventListener("message", onMessage);
    return () => removeEventListener("message", onMessage);
  }, [call.html]);
  const run = () => {
    ranRenders.add(call.html);
    setRunning(true);
  };
  const title = call.title ?? t("render.untitled");
  const tall = height > COLLAPSED_MAX_HEIGHT;
  return (
    <div className="acpmux-render-card">
      <div className="acpmux-render-card-head">
        <span className="acpmux-render-card-title" title={title}>
          {title}
        </span>
        {!running && (
          <button type="button" className="acpmux-review-changes" onClick={run}>
            {t("render.run")}
          </button>
        )}
        {running && tall && (
          <button
            type="button"
            className="acpmux-review-changes"
            aria-expanded={expanded}
            onClick={() => setExpanded((value) => !value)}
          >
            {expanded ? t("render.collapse") : t("render.expand")}
          </button>
        )}
      </div>
      {running && (
        <iframe
          ref={frame}
          className="acpmux-render-card-frame"
          src={RENDER_FRAME_URL}
          title={title}
          sandbox="allow-scripts"
          referrerPolicy="no-referrer"
          style={{ height: expanded ? height : Math.min(height, COLLAPSED_MAX_HEIGHT) }}
        />
      )}
    </div>
  );
}
