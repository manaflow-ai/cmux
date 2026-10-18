// A render card above a turn's answer (renderCall.ts): the agent's HTML, live, in the render frame
// (`cmux-agent://render/frame`, AgentPaneRenderFrame.swift). The frame is an origin of its own,
// sandboxed without same-origin, so the HTML cannot reach the pane, its bridge or acpmux; its
// policy allows no connection. The frame asks for the HTML once it loads and reports its height;
// the card grows to it, up to a cap a reader can lift. Outside liveRender it waits for Run:
// the frame shares the pane's web process, so a busy loop in agent HTML would freeze the pane. The
// liveRender lab uses a srcdoc frame on the dev server and allows requests through a small bridge.
// Outside the lab a dev call stays a plain tool row. Open hands the
// page to the side panel beside the chat (ArtifactPanel.tsx), with its source a tab away.
import { useContext, useEffect, useRef, useState } from "react";
import { useT } from "../i18n";
import { useLab } from "../labs";
import { ArtifactContext } from "./artifactPreview";
import { Expand } from "./icons";
import { renderFrameCSS } from "./renderBase";
import { RENDER_FRAME_MIN_HEIGHT, type RenderCall } from "./renderCall";
import { isReactRender, reactRenderPage, renderBridgeScript, RENDER_FRAME_DOC } from "./renderFrameDoc";
import { DEV_RENDER_FRAME_PATH } from "./renderFrameShell";
import { useRenderRequests } from "./useRenderRequests";

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

/// Whether the pane runs on the dev server, which serves the render frame at DEV_RENDER_FRAME_PATH
/// with the frame's own policy; elsewhere (tests, the gallery) the lab's frame is a srcdoc.
const devServer = () => import.meta.env?.DEV === true && /^https?:$/.test(location.protocol);

/// Feeds `html` to a render frame once it asks for it, and follows the height the frame reports.
export function useRenderFrame(
  html: string,
  live = false,
  request?: (data: Record<string, unknown>, target: Window) => void,
) {
  const frame = useRef<HTMLIFrameElement>(null);
  const [height, setHeight] = useState(RENDER_FRAME_MIN_HEIGHT);
  useEffect(() => {
    const onMessage = (event: MessageEvent) => {
      const target = frame.current?.contentWindow;
      if (!target || event.source !== target) return;
      const data: unknown = event.data;
      if (!data || typeof data !== "object") return;
      const message = data as { type?: unknown; height?: unknown };
      if (message.type === "cmux-render-ready") {
        const css = renderFrameCSS();
        const theme = getComputedStyle(document.body).colorScheme.includes("dark") ? "dark" : "light";
        const page = live && isReactRender(html) ? reactRenderPage(html) : html;
        target.postMessage(
          { type: "cmux-render", html: live ? "<!doctype html>" + renderBridgeScript(theme, css) + page : page, css },
          "*",
        );
      } else if (live && message.type === "cmux-render-request") request?.(data as Record<string, unknown>, target);
      else if (
        message.type === "cmux-render-size" &&
        typeof message.height === "number" &&
        Number.isFinite(message.height)
      )
        setHeight(Math.min(EXPANDED_MAX_HEIGHT, Math.max(RENDER_FRAME_MIN_HEIGHT, Math.ceil(message.height))));
    };
    addEventListener("message", onMessage);
    const theme = () =>
      frame.current?.contentWindow?.postMessage(
        {
          type: "cmux-render-theme",
          theme: getComputedStyle(document.body).colorScheme.includes("dark") ? "dark" : "light",
          css: renderFrameCSS(),
        },
        "*",
      );
    const observer = live ? new MutationObserver(theme) : undefined;
    observer?.observe(document.documentElement, { attributes: true });
    observer?.observe(document.body, { attributes: true });
    observer?.observe(document.head, { childList: true, subtree: true, characterData: true });
    const scheme = live && typeof matchMedia === "function" ? matchMedia("(prefers-color-scheme: dark)") : undefined;
    scheme?.addEventListener("change", theme);
    return () => {
      removeEventListener("message", onMessage);
      observer?.disconnect();
      scheme?.removeEventListener("change", theme);
    };
  }, [html, live, request]);
  return { frame, height };
}

export function RenderCard({ call, panel = false }: { call: RenderCall; panel?: boolean }) {
  const t = useT();
  const live = useLab("liveRender");
  const open = useContext(ArtifactContext);
  const requests = useRenderRequests(call.html);
  const { frame, height } = useRenderFrame(call.html, live, requests.request);
  const [expanded, setExpanded] = useState(false);
  // Auto-run trades the Run gate for immediacy. A busy loop still blocks the shared web process
  // (Lucas 2026-10-18); Stop unloads cooperative pages, but cannot interrupt that loop.
  const [ran, setRan] = useState(() => ranRenders.has(call.html));
  const [stopped, setStopped] = useState(false);
  const running = live ? !stopped : ran;
  const run = () => {
    ranRenders.add(call.html);
    setRan(true);
    setStopped(false);
  };
  const title = call.title ?? t("render.untitled");
  const tall = height > COLLAPSED_MAX_HEIGHT;
  return (
    <div className={panel ? "acpmux-render-card acpmux-render-card--panel" : "acpmux-render-card"}>
      <div className="acpmux-render-card-head">
        <span className="acpmux-render-card-title">{title}</span>
        {!running && (
          <button type="button" className="acpmux-review-changes" onClick={run}>
            {t("render.run")}
          </button>
        )}
        {live && running && (
          <button
            type="button"
            className="acpmux-review-changes"
            onClick={() => {
              requests.cancel();
              ranRenders.delete(call.html);
              setRan(false);
              setStopped(true);
            }}
          >
            {t("render.stop")}
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
        {open && !panel && (
          <button
            type="button"
            className="cv-iconbtn cv-iconbtn--compact"
            aria-label={t("artifact.open")}
            title={t("artifact.open")}
            onClick={() =>
              open({
                kind: live && isReactRender(call.html) ? "react" : "html",
                lang: live && isReactRender(call.html) ? "cmux-react" : "html",
                code: call.html,
              })
            }
          >
            <Expand />
          </button>
        )}
      </div>
      {running && (
        <iframe
          key={live ? call.html : undefined}
          ref={frame}
          className={panel ? "acpmux-artifact-frame" : "acpmux-render-card-frame"}
          src={live && !canRender() ? (devServer() ? DEV_RENDER_FRAME_PATH : undefined) : RENDER_FRAME_URL}
          srcDoc={live && !canRender() && !devServer() ? RENDER_FRAME_DOC : undefined}
          title={title}
          sandbox="allow-scripts"
          referrerPolicy="no-referrer"
          style={panel ? undefined : { height: expanded ? height : Math.min(height, COLLAPSED_MAX_HEIGHT) }}
        />
      )}
      {live && running && requests.pending && (
        <div className="acpmux-render-confirm">
          <span>{requests.pending.text}</span>
          <button type="button" className="acpmux-review-changes" onClick={() => requests.confirm(false)}>
            {requests.pending.method === "openLink" ? t("render.open") : t("composer.send")}
          </button>
          {requests.pending.method === "sendPrompt" && (
            <button type="button" className="acpmux-review-changes" onClick={() => requests.confirm(true)}>
              {t("render.edit")}
            </button>
          )}
        </div>
      )}
      {live && requests.copied && <output className="acpmux-render-note">{t("turn.copied")}</output>}
    </div>
  );
}
