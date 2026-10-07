// A render card above a turn's answer (renderCall.ts): the agent's HTML, live, in the render frame
// (`cmux-agent://render/frame`, AgentPaneRenderFrame.swift). The frame is an origin of its own,
// sandboxed without same-origin, so the HTML cannot reach the pane, its bridge or acpmux; its
// policy allows no connection. The frame asks for the HTML once it loads and reports its height;
// the card grows to it, up to a cap a reader can lift. A pane on a dev server has a render frame
// only when its host names one (the `ready` answer's `renderFrame`, as the gallery's does), with
// the same document (renderFrame.html); else the call stays a plain tool row.
import { useEffect, useRef, useState } from "react";
import { useT } from "../i18n";
import { RENDER_FRAME_MIN_HEIGHT, type RenderCall } from "./renderCall";

export const RENDER_FRAME_URL = "cmux-agent://render/frame";
/// The tallest a card draws until the reader expands it; a card among options is shorter.
const COLLAPSED_MAX_HEIGHT = 560;
const COMPACT_MAX_HEIGHT = 320;
/// The tallest an expanded card draws; a taller page scrolls inside it.
const EXPANDED_MAX_HEIGHT = 4000;

let frameURL: string | undefined =
  typeof location !== "undefined" && location.protocol === "cmux-agent:" ? RENDER_FRAME_URL : undefined;

/// The frame a host serves renderFrame.html at, from its `ready` answer; the bundled pane keeps
/// its own render origin.
export function setRenderFrame(url: unknown) {
  if (frameURL === RENDER_FRAME_URL || typeof url !== "string") return;
  try {
    const parsed = new URL(url);
    if (parsed.protocol === "http:" || parsed.protocol === "https:") frameURL = parsed.href;
  } catch {
    // Not a URL: no render frame.
  }
}

/// Whether this page can frame renders: the bundled pane's render origin, or a host's frame.
export const canRender = () => frameURL !== undefined;

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

/// One render. Among options (RenderGroup.tsx) it is `compact`: shorter, and Expand asks the group
/// to show it alone (`onExpand`), opened (`startExpanded`).
export function RenderCard({
  call,
  compact = false,
  startExpanded = false,
  onExpand,
}: {
  call: RenderCall;
  compact?: boolean;
  startExpanded?: boolean;
  onExpand?: () => void;
}) {
  const t = useT();
  const frame = useRef<HTMLIFrameElement>(null);
  const [height, setHeight] = useState(RENDER_FRAME_MIN_HEIGHT);
  const [expanded, setExpanded] = useState(startExpanded);
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
  const title = call.title ?? t("render.untitled");
  const cap = compact ? COMPACT_MAX_HEIGHT : COLLAPSED_MAX_HEIGHT;
  const tall = height > cap;
  return (
    <div className="acpmux-render-card">
      <div className="acpmux-render-card-head">
        <span className="acpmux-render-card-title" title={title}>
          {title}
        </span>
        {call.recommended && <span className="acpmux-render-card-recommended">{t("render.recommended")}</span>}
        {onExpand ? (
          <button type="button" className="acpmux-review-changes" onClick={onExpand}>
            {t("render.expand")}
          </button>
        ) : (
          tall && (
          <button
            type="button"
            className="acpmux-review-changes"
            aria-expanded={expanded}
            onClick={() => setExpanded((value) => !value)}
          >
            {expanded ? t("render.collapse") : t("render.expand")}
          </button>
          )
        )}
      </div>
      <iframe
        ref={frame}
        className="acpmux-render-card-frame"
        src={frameURL}
        title={title}
        sandbox="allow-scripts"
        referrerPolicy="no-referrer"
        style={{ height: expanded ? height : Math.min(height, cap) }}
      />
    </div>
  );
}
