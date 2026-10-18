// A render card above a turn's answer (renderCall.ts): the agent's HTML, live, in the render frame
// (`cmux-agent://render/frame`, AgentPaneRenderFrame.swift). The frame is an origin of its own,
// sandboxed without same-origin, so the HTML cannot reach the pane, its bridge or acpmux; its
// policy allows no connection. The frame asks for the HTML once it loads and reports its height;
// the card grows to it, up to a cap a reader can lift. Outside liveRender it waits for Run:
// the frame shares the pane's web process, so a busy loop in agent HTML would freeze the pane. The
// liveRender lab uses a srcdoc frame on the dev server and allows requests through a small bridge.
// Outside the lab a dev call stays a plain tool row. Open hands the
// page to the side panel beside the chat (ArtifactPanel.tsx), with its source a tab away.
import { useContext, useEffect, useLayoutEffect, useRef, useState } from "react";
import { useT } from "../i18n";
import { useLab } from "../labs";
import { ArtifactContext, documentName } from "./artifactPreview";
import { Expand } from "./icons";
import { renderFrameCSS } from "./renderBase";
import { RENDER_FRAME_MIN_HEIGHT, type RenderCall } from "./renderCall";
import { isReactRender, reactRenderPage, renderBridgeScript, RENDER_FRAME_DOC } from "./renderFrameDoc";
import { DEV_RENDER_FRAME_PATH } from "./renderFrameShell";
import { useRenderRequests } from "./useRenderRequests";
import { ChatSessionContext, TranscriptRowContext } from "./viewIdentity";
import { stopRender, useRenderStopped } from "./renderState";

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
        if (live) setHeight(RENDER_FRAME_MIN_HEIGHT);
        const css = renderFrameCSS();
        const theme = getComputedStyle(document.body).colorScheme.includes("dark") ? "dark" : "light";
        const page = live && isReactRender(html) ? reactRenderPage(html) : html;
        target.postMessage(
          { type: "cmux-render", html: live ? "<!doctype html>" + renderBridgeScript(theme, css) + page : page, css },
          "*",
        );
      } else if (live && message.type === "cmux-render-request") request?.(data as Record<string, unknown>, target);
      else if (
        message.type === (live ? "cmux-render-content-size" : "cmux-render-size") &&
        typeof message.height === "number" &&
        Number.isFinite(message.height)
      )
        setHeight(
          Math.min(EXPANDED_MAX_HEIGHT, Math.max(live ? 48 : RENDER_FRAME_MIN_HEIGHT, Math.ceil(message.height))),
        );
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
  const sessionId = useContext(ChatSessionContext);
  const rowId = useContext(TranscriptRowContext);
  const identity = rowId ? [rowId, call.id ?? ""] : (call.id ?? call.html);
  const key = JSON.stringify([sessionId, identity]);
  const requests = useRenderRequests(key);
  const { frame, height } = useRenderFrame(call.html, live, requests.request);
  const [expanded, setExpanded] = useState(false);
  // Auto-run trades the Run gate for immediacy. A busy loop still blocks the shared web process
  // (Lucas 2026-10-18); Stop unloads cooperative pages, but cannot interrupt that loop.
  const [ran, setRan] = useState(() => ranRenders.has(call.html));
  const stopped = useRenderStopped(key);
  const running = live ? !stopped : ran;
  const run = () => {
    ranRenders.add(call.html);
    setRan(true);
    stopRender(key, false);
  };
  const title = call.title ?? (live ? renderTitle(call.html) || t("render.untitled") : t("render.untitled"));
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
            className="acpmux-review-changes acpmux-render-stop"
            aria-label={t("render.stop")}
            onClick={() => {
              requests.cancel();
              ranRenders.delete(call.html);
              setRan(false);
              stopRender(key, true);
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
            className={`cv-iconbtn cv-iconbtn--compact${live ? " acpmux-render-open" : ""}`}
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
      {live && running && requests.pending && <RenderConfirm key={requests.pending.text} requests={requests} />}
      {live && requests.copied && <output className="acpmux-render-note">{t("turn.copied")}</output>}
    </div>
  );
}

/// A page asks before sending; long drafts stay readable without filling the card (Lucas 2026-10-18).
function RenderConfirm({ requests }: { requests: ReturnType<typeof useRenderRequests> }) {
  const t = useT();
  const text = useRef<HTMLDivElement>(null);
  const [expanded, setExpanded] = useState(false);
  const [long, setLong] = useState(false);
  const pending = requests.pending!;
  useLayoutEffect(() => {
    const node = text.current;
    if (!node || expanded) return;
    const measure = () => setLong(node.scrollHeight > node.clientHeight + 1);
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(node);
    return () => observer.disconnect();
  }, [pending.text, expanded]);
  return (
    // oxlint-disable-next-line jsx-a11y/no-noninteractive-element-interactions -- Escape cancels from the buttons inside, as in ArtifactPanel.
    <section
      aria-label={pending.method === "sendPrompt" ? t("render.sendToChat") : t("render.open")}
      className="acpmux-render-confirm"
      // ui-allow: Escape cancels this draft from any control in its confirmation strip.
      onKeyDown={(event) => {
        if (event.key === "Escape") {
          event.stopPropagation();
          event.preventDefault();
          requests.cancel();
        }
      }}
    >
      <div className="acpmux-render-confirm-draft">
        <span className="acpmux-render-confirm-label">
          {pending.method === "sendPrompt" ? t("render.sendToChat") : t("render.open")}
        </span>
        <div ref={text} className={`acpmux-render-confirm-text${expanded ? " is-expanded" : ""}`}>
          {pending.text}
        </div>
        {long && (
          <button
            type="button"
            className="acpmux-review-changes"
            aria-expanded={expanded}
            onClick={() => setExpanded(!expanded)}
          >
            {expanded ? t("shell.showLess") : t("render.showAll")}
          </button>
        )}
      </div>
      <div className="acpmux-render-confirm-actions">
        <button type="button" className="acpmux-ask-action is-primary" onClick={() => requests.confirm(false)}>
          {pending.method === "openLink" ? t("render.open") : t("composer.send")}
        </button>
        {pending.method === "sendPrompt" && (
          <button type="button" className="acpmux-review-changes" onClick={() => requests.confirm(true)}>
            {t("render.edit")}
          </button>
        )}
        <button type="button" className="acpmux-review-changes acpmux-render-cancel" onClick={requests.cancel}>
          {t("edited.cancel")}
        </button>
      </div>
    </section>
  );
}

/// Agent-authored names stay in the page; unnamed cards keep Preview (Lucas 2026-10-18).
export function renderTitle(html: string): string {
  const title = documentName({ kind: "html", lang: "html", code: html });
  if (title || !isReactRender(html)) return title;
  return (
    /^\s*\/\/\s*title:\s*([^\r\n]+)/i.exec(html.trimStart().slice("<!-- cmux-react -->".length))?.[1]?.trim() ?? ""
  );
}
