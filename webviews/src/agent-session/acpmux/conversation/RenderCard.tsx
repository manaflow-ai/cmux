// A render card above a turn's answer (renderCall.ts): the agent's HTML, live, in the render frame
// (`cmux-agent://render/frame`, AgentPaneRenderFrame.swift). The frame is an origin of its own,
// sandboxed without same-origin, so the HTML cannot reach the pane, its bridge or acpmux; its
// policy allows no connection. The frame asks for the HTML once it loads and reports its height;
// the card grows to it, up to a cap a reader can lift. Nothing runs until the reader presses Run:
// the frame shares the pane's web process, so a busy loop in agent HTML would freeze the pane. The
// pane on a dev server has no render frame, so there the call stays a plain tool row. Open hands the
// page to the side panel beside the chat (ArtifactPanel.tsx), with its source a tab away.
import { type ReactNode, useContext, useEffect, useRef, useState } from "react";
import { useT } from "../i18n";
import { ArtifactContext } from "./artifactPreview";
import { Expand } from "./icons";
import type { AcpmuxActivity } from "../model";
import { renderFrameCSS } from "./renderBase";
import { RENDER_FRAME_MIN_HEIGHT, RenderPages, renderCall, type RenderCall } from "./renderCall";

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

/// Feeds `html` to a render frame once it asks for it, and follows the height the frame reports.
export function useRenderFrame(html: string) {
  const frame = useRef<HTMLIFrameElement>(null);
  const [height, setHeight] = useState(RENDER_FRAME_MIN_HEIGHT);
  useEffect(() => {
    const onMessage = (event: MessageEvent) => {
      const target = frame.current?.contentWindow;
      if (!target || event.source !== target) return;
      const data: unknown = event.data;
      if (!data || typeof data !== "object") return;
      const message = data as { type?: unknown; height?: unknown };
      if (message.type === "cmux-render-ready")
        target.postMessage({ type: "cmux-render", html, css: renderFrameCSS() }, "*");
      else if (
        message.type === "cmux-render-size" &&
        typeof message.height === "number" &&
        Number.isFinite(message.height)
      )
        setHeight(Math.min(EXPANDED_MAX_HEIGHT, Math.max(RENDER_FRAME_MIN_HEIGHT, Math.ceil(message.height))));
    };
    addEventListener("message", onMessage);
    return () => removeEventListener("message", onMessage);
  }, [html]);
  return { frame, height };
}

/// `card` is a render tool call's card key (renderCall.ts `renderPages`): Open hands it with the page.
export function RenderCard({ call, card, actions }: { call: RenderCall; card?: string; actions?: ReactNode }) {
  const t = useT();
  const open = useContext(ArtifactContext);
  const { frame, height } = useRenderFrame(call.html);
  const [expanded, setExpanded] = useState(false);
  const [running, setRunning] = useState(() => ranRenders.has(call.html));
  const run = () => {
    ranRenders.add(call.html);
    setRunning(true);
  };
  const title = call.title ?? t("render.untitled");
  const tall = height > COLLAPSED_MAX_HEIGHT;
  return (
    <div className="acpmux-render-card">
      <div className="acpmux-render-card-head">
        <span className="acpmux-render-card-title">{title}</span>
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
        {open && (
          <button
            type="button"
            className="cv-iconbtn cv-iconbtn--compact"
            aria-label={t("artifact.open")}
            title={t("artifact.open")}
            onClick={() => open({ kind: "html", lang: "html", code: call.html, ...(card && { render: card }) })}
          >
            <Expand />
          </button>
        )}
        {actions}
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

/// A render tool call's card (renderCall.ts `renderPages`). A call that starts a card draws it with the
/// card's latest page (cx-ncc.94); an update that joined an earlier card draws nothing of its own. Each
/// page is its own card instance, so a new page waits for Run like any other.
export function RenderToolCard({ tool }: { tool: NonNullable<AcpmuxActivity["tool"]> }) {
  const pages = useContext(RenderPages);
  const page = pages?.get(tool.id);
  if (page && page.first !== tool.id) return null;
  const shown = page?.calls.at(-1) ?? renderCall(tool);
  return shown ? <RenderCard key={shown.html} call={shown} card={page?.first} /> : null;
}
