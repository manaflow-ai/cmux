// A render card above a turn's answer (renderCall.ts): the agent's HTML, live, in the render frame
// (`cmux-agent://render/frame`, AgentPaneRenderFrame.swift). The frame is an origin of its own,
// sandboxed without same-origin, so the HTML cannot reach the pane, its bridge or acpmux; its
// policy allows no connection. The frame asks for the HTML once it loads and reports its height;
// the card grows to it, up to a cap a reader can lift. Nothing runs until the reader presses Run:
// the frame shares the pane's web process, so a busy loop in agent HTML would freeze the pane. The
// pane on a dev server has no render frame, so there the call stays a plain tool row. Open hands the
// page to the side panel beside the chat (ArtifactPanel.tsx), with its source a tab away.
import { type ReactNode, useContext, useState } from "react";
import { useT } from "../i18n";
import { ArtifactContext } from "./artifactPreview";
import { ChevronDown, Expand, PlayTriangle } from "./icons";
import "./cardFit.css";
import type { AcpmuxActivity } from "../model";
import { ranRenders, useRenderFrame } from "./renderFrame";
import { RenderPages, renderCall, type RenderCall } from "./renderCall";
import { RENDER_FRAME_URL } from "./renderCardModel";
/// The tallest a card draws until the reader expands it.
const COLLAPSED_MAX_HEIGHT = 560;

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
    <div className="acpmux-render-card cv-fit">
      <div className="acpmux-render-card-head cv-fit-row">
        <span
          className="acpmux-render-card-title cv-fit-text"
          // tooltip-allow: a long title is cut to the line beside its buttons; its whole text is the tooltip
          title={title}
        >
          {title}
        </span>
        {/* The buttons wrap under the title in a narrow card and shrink to icons (cardFit.css). */}
        <span className="cv-fit-actions">
          {!running && (
            <button
              type="button"
              className="acpmux-review-changes"
              title={t("render.run")}
              aria-label={t("render.run")}
              onClick={run}
            >
              <PlayTriangle size={12} />
              <span className="cv-fit-label">{t("render.run")}</span>
            </button>
          )}
          {running && tall && (
            <button
              type="button"
              className="acpmux-review-changes"
              aria-expanded={expanded}
              title={expanded ? t("render.collapse") : t("render.expand")}
              aria-label={expanded ? t("render.collapse") : t("render.expand")}
              onClick={() => setExpanded((value) => !value)}
            >
              {expanded ? <ChevronDown size={12} /> : <Expand size={12} />}
              <span className="cv-fit-label">{expanded ? t("render.collapse") : t("render.expand")}</span>
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
        </span>
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
