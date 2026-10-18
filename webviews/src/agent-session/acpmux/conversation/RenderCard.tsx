// Agent HTML stays in one opaque frame. liveRender streams into its runtime; the lab off
// keeps the original Run gate and card controls (Lucas 2026-10-18).
import { useContext, useEffect, useLayoutEffect, useRef, useState } from "react";
import { translate, useT } from "../i18n";
import { useLab } from "../labs";
import { ArtifactContext, documentName } from "./artifactPreview";
import { Expand } from "./icons";
import { Dialog } from "../../../ui/Dialog";
import { renderFrameCSS, embeddedFrameCSS } from "./renderBase";
import { RENDER_FRAME_MIN_HEIGHT, type RenderCall } from "./renderCall";
import { isReactRender, reactRenderPage, renderBridgeScript } from "./renderFrameDoc";
import { devRenderFrameURL, LIVE_RENDER_FRAME_DOC } from "./renderFrameShell";
import { RenderBridgeContext } from "./RenderBridgeContext";
import { useRenderRequests } from "./useRenderRequests";
import { ChatSessionContext, TranscriptRowContext } from "./viewIdentity";
import { renderStreamScript } from "./renderStreamRuntime";

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
/// The theme for a page embedded in the chat: no side inset, so it lines up with the reply's text
/// (Lucas 2026-10-18); a page's own `body` margin still wins.


export function useRenderFrame(
  html: string,
  live = false,
  request?: (data: Record<string, unknown>, target: Window) => void,
  streaming = false,
  frozen = false,
  kit = false,
) {
  const frame = useRef<HTMLIFrameElement>(null);
  const [height, setHeight] = useState(live ? 0 : RENDER_FRAME_MIN_HEIGHT);
  const latest = useRef({ html, streaming, request, frozen });
  latest.current = { html, streaming, request, frozen };
  const [error, setError] = useState<string>();
  const measured = useRef(height);
  useEffect(() => {
    if (!frozen) setHeight(measured.current);
  }, [frozen]);
  const schedule = useRef<() => void>(() => {});
  useLayoutEffect(() => {
    setError(undefined);
    let reportedError = false;
    let booted = false,
      ready = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    let animation: number | undefined;
    let lastFlush = -Infinity;
    let preparingReact = false;
    let sent: { html: string; done: boolean } | undefined;
    const flush = () => {
      timer = undefined;
      animation = undefined;
      if (!ready) return;
      const { html, streaming } = latest.current;
      if (isReactRender(html) && streaming && !preparingReact) {
        preparingReact = true;
        frame.current?.contentWindow?.postMessage(
          { type: "cmux-render-react-prepare", errorText: translate("render.loadFailed") },
          "*",
        );
      }
      if (isReactRender(html) && streaming) return;
      const page = isReactRender(html) ? reactRenderPage(html) : html;
      const done = !streaming;
      if (sent?.html === page && sent.done === done) return;
      frame.current?.contentWindow?.postMessage({ type: "cmux-render-stream", html: page, done }, "*");
      sent = { html: page, done };
      lastFlush = performance.now();
    };
    schedule.current = () => {
      if (!ready || timer !== undefined || animation !== undefined) return;
      if (!sent) return flush();
      const nextFrame = () => {
        timer = undefined;
        animation = requestAnimationFrame(flush);
      };
      const remaining = 50 - (performance.now() - lastFlush);
      if (remaining > 0) timer = setTimeout(nextFrame, remaining);
      else nextFrame();
    };
    const onMessage = (event: MessageEvent) => {
      const target = frame.current?.contentWindow;
      if (!target || event.source !== target) return;
      const data: unknown = event.data;
      if (!data || typeof data !== "object") return;
      const message = data as { type?: unknown; height?: unknown; error?: unknown };
      if (message.type === "cmux-render-ready" && !booted && !ready) {
        booted = true;
        const css = live ? embeddedFrameCSS() : renderFrameCSS();
        const theme = getComputedStyle(document.body).colorScheme.includes("dark") ? "dark" : "light";
        target.postMessage(
          {
            type: "cmux-render",
            html: live
              ? "<!doctype html><html><head>" +
                renderBridgeScript(theme, css) +
                renderStreamScript() +
                "</head><body></body></html>"
              : latest.current.html,
            css,
          },
          "*",
        );
      } else if (live && message.type === "cmux-render-stream-ready") {
        if (ready) return;
        ready = true;
        target.postMessage({ type: "cmux-render-kit", enabled: kit }, "*");
        theme();
        schedule.current();
      } else if (live && kit && message.type === "cmux-render-error" && typeof message.error === "string") {
        const text = message.error.replace(/\s+/g, " ").trim().slice(0, 200);
        if (text && !reportedError) {
          reportedError = true;
          setError(text);
        }
      } else if (live && message.type === "cmux-render-request")
        latest.current.request?.(data as Record<string, unknown>, target);
      else if (
        message.type === (live ? "cmux-render-content-size" : "cmux-render-size") &&
        typeof message.height === "number" &&
        Number.isFinite(message.height)
      ) {
        measured.current = Math.min(
          live ? 1600 : EXPANDED_MAX_HEIGHT,
          Math.max(live ? 0 : RENDER_FRAME_MIN_HEIGHT, Math.ceil(message.height)),
        );
        if (!latest.current.frozen) setHeight(measured.current);
      }
    };
    addEventListener("message", onMessage);
    let themeCSS: string | undefined;
    const theme = () => {
      const css = embeddedFrameCSS();
      if (css === themeCSS) return;
      themeCSS = css;
      frame.current?.contentWindow?.postMessage(
        {
          type: "cmux-render-theme",
          theme: getComputedStyle(document.body).colorScheme.includes("dark") ? "dark" : "light",
          css,
        },
        "*",
      );
    };
    const observer = live ? new MutationObserver(theme) : undefined;
    observer?.observe(document.documentElement, { attributes: true });
    observer?.observe(document.body, { attributes: true });
    observer?.observe(document.head, { childList: true, subtree: true, characterData: true });
    const scheme = live && typeof matchMedia === "function" ? matchMedia("(prefers-color-scheme: dark)") : undefined;
    scheme?.addEventListener("change", theme);
    return () => {
      clearTimeout(timer);
      if (animation !== undefined) cancelAnimationFrame(animation);
      schedule.current = () => {};
      removeEventListener("message", onMessage);
      observer?.disconnect();
      scheme?.removeEventListener("change", theme);
    };
  }, [live, kit]);
  useEffect(() => schedule.current(), [html, streaming]);
  return { frame, height, error };
}

export function RenderCard({
  call,
  panel = false,
  streaming = false,
}: {
  call: RenderCall;
  panel?: boolean;
  streaming?: boolean;
}) {
  const t = useT();
  const live = useLab("liveRender");
  const renderExpand = useLab("renderExpand");
  const [large, setLarge] = useState(false);
  const expandButton = useRef<HTMLButtonElement>(null);
  const kit = useLab("renderKit") && live;
  const bridge = useContext(RenderBridgeContext);
  const open = useContext(ArtifactContext);
  const sessionId = useContext(ChatSessionContext);
  const rowId = useContext(TranscriptRowContext);
  const identity = rowId ? [rowId, call.id ?? ""] : (call.id ?? call.html);
  const key = JSON.stringify([sessionId, identity]);
  const requests = useRenderRequests(key);
  const { frame, height, error } = useRenderFrame(
    call.html,
    live,
    requests.request,
    streaming,
    live && !!requests.pending,
    kit,
  );
  const [expanded, setExpanded] = useState(false);
  const [ran, setRan] = useState(() => ranRenders.has(call.html));
  const running = live || ran;
  const run = () => {
    ranRenders.add(call.html);
    setRan(true);
  };
  const title = call.title ?? (live ? renderTitle(call.html) || t("render.untitled") : t("render.untitled"));
  const repairName = (call.title || renderTitle(call.html)).replace(/\s+/g, " ").trim().slice(0, 100);
  const tall = height > COLLAPSED_MAX_HEIGHT;
  return (
    <div
      className={panel ? "acpmux-render-card acpmux-render-card--panel" : "acpmux-render-card"}
      style={live && streaming && isReactRender(call.html) ? { display: "none" } : undefined}
    >
      {live && renderExpand && !panel && !streaming && !requests.pending && (
        <button
          type="button"
          ref={expandButton}
          className="cv-iconbtn cv-iconbtn--compact acpmux-render-enlarge"
          aria-label={t("artifact.open")}
          title={t("artifact.open")}
          onClick={() => setLarge(true)}
        >
          <Expand />
        </button>
      )}
      {large && (
        <Dialog
          open={large}
          onOpenChange={setLarge}
          label={title}
          finalFocus={expandButton}
          className="acpmux-render-dialog"
          backdropClassName="acpmux-image-viewer-backdrop"
        >
          <div className="acpmux-render-dialog-head">
            <span>{title}</span>
            <button type="button" className="acpmux-review-changes" onClick={() => setLarge(false)}>
              {t("artifact.close")}
            </button>
          </div>
          <div className="acpmux-render-dialog-body">
            <RenderCard call={call} panel />
          </div>
        </Dialog>
      )}
      {!live && (
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
          {open && !panel && (
            <button
              type="button"
              className="cv-iconbtn cv-iconbtn--compact"
              aria-label={t("artifact.open")}
              title={t("artifact.open")}
              onClick={() =>
                open({
                  kind: "html",
                  lang: "html",
                  code: call.html,
                })
              }
            >
              <Expand />
            </button>
          )}
        </div>
      )}
      {running && (
        <iframe
          key={`${live}:${kit}`}
          ref={frame}
          className={panel ? "acpmux-artifact-frame" : "acpmux-render-card-frame"}
          src={live && !canRender() ? (devServer() ? devRenderFrameURL(location.href) : undefined) : RENDER_FRAME_URL}
          srcDoc={live && !canRender() && !devServer() ? LIVE_RENDER_FRAME_DOC : undefined}
          title={title}
          sandbox="allow-scripts"
          referrerPolicy="no-referrer"
          style={
            panel && !live ? undefined : { height: live || expanded ? height : Math.min(height, COLLAPSED_MAX_HEIGHT) }
          }
        />
      )}
      {kit && error && (
        <div className="acpmux-render-note" role="status" style={{ display: "flex", alignItems: "baseline", gap: 8 }}>
          <span style={{ overflow: "hidden", display: "-webkit-box", WebkitLineClamp: 2, WebkitBoxOrient: "vertical" }}>
            {t("render.error")} {error}
          </span>
          {bridge && (
            <button
              type="button"
              className="acpmux-review-changes"
              style={{ flexShrink: 0 }}
              // l10n-allow: repair context sent to the agent
              onClick={() =>
                bridge.prefill(
                  `Please fix ${repairName ? `the chat render ${JSON.stringify(repairName)}` : "this chat render"}. Render error: ${error}`,
                )
              }
            >
              {t("render.askToFix")}
            </button>
          )}
        </div>
      )}
      {live && running && requests.pending && <RenderConfirm requests={requests} />}
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
  const appeared = useRef(0);
  useLayoutEffect(() => {
    // Give the reader time to see each request before its buttons accept a click (Lucas 2026-10-18).
    appeared.current = Date.now();
    setExpanded(false);
  }, [pending]);
  const label =
    pending.method === "sendPrompt"
      ? t("render.sendToChat")
      : pending.method === "copy"
        ? t("render.copy")
        : pending.method === "prefill"
          ? t("render.edit")
          : t("render.open");
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
      aria-label={label}
      className="acpmux-render-confirm"
      // ui-allow: A new request cannot borrow a click meant for the page beneath it.
      onClickCapture={(event) => {
        if (Date.now() - appeared.current < 500) {
          event.preventDefault();
          event.stopPropagation();
        }
      }}
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
        <span className="acpmux-render-confirm-label">{label}</span>
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
          {pending.method === "sendPrompt" ? t("composer.send") : label}
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
