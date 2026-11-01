// A closed ```html or ```svg fence in a reply, drawn as the document it holds (leo-workspace
// design/artifacts.md). The preview is an iframe sandboxed with `allow-scripts` and no
// `allow-same-origin`, whose `srcdoc` starts with the artifact policy: no network, and before Run no
// script but the client's own height reporter (previewDocument.ts). Its height follows the frame's
// report, accepted only from that frame's window, capped at 480 px (Expand lifts the cap), and the
// document scrolls past it. A document that carries script draws as its source with Run, as the
// side panel does (#26216): Run moves it to the native artifact frame, whose navigation delegate also
// refuses self-navigation; a page without one (the gallery) runs it in srcdoc. Code shows the source
// card, which keeps Copy. Markdown.tsx draws this only once the fence has closed: an open fence stays
// plain code, so no frame is made or reloaded per token. The frame mounts once the card nears the
// viewport, so a long chat does not start every frame at once.
import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { useT } from "../i18n";
import { useNearViewport } from "../useNearViewport";
import { artifactFrameURL, artifactGallery, artifactNeedsRun } from "./artifactSandbox";
import { CodeBlock, languageLabel } from "./CodeBlock";
import { CopyButton } from "./CopyButton";
import { OpenPreview } from "./OpenPreview";
import { renderFrameCSS } from "./renderBase";
import { useRenderFrame } from "./RenderCard";
import {
  INLINE_PREVIEW_EXPANDED_MAX_HEIGHT,
  INLINE_PREVIEW_MAX_HEIGHT,
  INLINE_PREVIEW_MIN_HEIGHT,
  INLINE_PREVIEW_SANDBOX,
  inlinePreviewDocument,
  previewNonce,
  reportedHeight,
} from "./previewDocument";

export function InlinePreview({
  kind,
  code,
  lang,
  actions,
}: {
  kind: "html" | "svg";
  code: string;
  lang: string;
  actions?: ReactNode;
}) {
  const t = useT();
  const [showCode, setShowCode] = useState(false);
  const [expanded, setExpanded] = useState(false);
  const scripted = useMemo(() => artifactNeedsRun(code), [code]);
  // Run authorizes this fenced document only. A global code-text cache would auto-run the same
  // scripted snippet when it appears later in a different chat, without a click there.
  const [running, setRunning] = useState(false);
  // The frame left its document (its frame counts its loads): the card shows the source.
  const [left, setLeft] = useState(false);
  // Run needs a frame that may run script: the native artifact frame, or the gallery's srcdoc.
  const canRun = scripted && (artifactFrameURL() !== undefined || artifactGallery());
  const toggle = (
    <button
      type="button"
      className="cv-codeblock__action cv-codeblock__action--text"
      aria-pressed={showCode}
      onClick={() => setShowCode((value) => !value)}
    >
      {showCode ? t("artifact.preview") : t("artifact.code")}
    </button>
  );
  // Source view, and a scripted document before Run: the code card, which keeps Copy and Open.
  if (left) return <CodeBlock code={code} lang={lang} actions={actions} />;
  if (showCode || (scripted && !running))
    return (
      <CodeBlock
        code={code}
        lang={lang}
        actions={
          <>
            {scripted && !running && canRun && (
              <button
                type="button"
                className="cv-codeblock__action cv-codeblock__action--text"
                onClick={() => {
                  setRunning(true);
                  setShowCode(false);
                }}
              >
                {t("render.run")}
              </button>
            )}
            {(!scripted || running) && toggle}
            {actions}
          </>
        }
      />
    );
  return (
    <FrameCard
      kind={kind}
      code={code}
      lang={lang}
      run={scripted}
      expanded={expanded}
      onExpand={() => setExpanded((value) => !value)}
      onLeave={() => setLeft(true)}
      head={
        <>
          {toggle}
          <OpenPreview code={code} lang={lang} />
          <CopyButton text={code} label={t("code.copy")} />
          {actions}
        </>
      }
    />
  );
}

function FrameCard({
  kind,
  code,
  lang,
  run,
  expanded,
  onExpand,
  onLeave,
  head,
}: {
  kind: "html" | "svg";
  code: string;
  lang: string;
  run: boolean;
  expanded: boolean;
  onExpand(): void;
  onLeave(): void;
  head: ReactNode;
}) {
  const t = useT();
  const [card, setCard] = useState<HTMLDivElement | null>(null);
  const near = useNearViewport(card);
  const [height, setHeight] = useState(INLINE_PREVIEW_MIN_HEIGHT);
  const max = expanded ? INLINE_PREVIEW_EXPANDED_MAX_HEIGHT : INLINE_PREVIEW_MAX_HEIGHT;
  const tall = height > INLINE_PREVIEW_MAX_HEIGHT;
  return (
    <div ref={setCard} className="acpmux-render-card cv-inline-preview" data-kind={kind}>
      <div className="acpmux-render-card-head">
        <span className="acpmux-render-card-title">{languageLabel(lang, t)}</span>
        {tall && (
          <button type="button" className="acpmux-review-changes" aria-expanded={expanded} onClick={onExpand}>
            {expanded ? t("render.collapse") : t("render.expand")}
          </button>
        )}
        <span className="cv-codeblock__actions">{head}</span>
      </div>
      {near &&
        (run && artifactFrameURL() ? (
          <NativeFrame code={code} max={max} onHeight={setHeight} />
        ) : (
          <SrcdocFrame kind={kind} code={code} passive={!run} max={max} onHeight={setHeight} onLeave={onLeave} />
        ))}
    </div>
  );
}

/// Passive markup (or, in the gallery, a run document) in srcdoc. The height listener takes only
/// this frame's own messages. A second load means the frame navigated away from its document (past
/// the frame script's guards, previewDocument.ts): whatever it loaded runs without the policy, so the
/// frame goes and the card shows the source.
function SrcdocFrame({
  kind,
  code,
  passive,
  max,
  onHeight,
  onLeave,
}: {
  kind: "html" | "svg";
  code: string;
  passive: boolean;
  max: number;
  onHeight(height: number): void;
  onLeave(): void;
}) {
  const t = useT();
  const title = languageLabel(kind, t);
  const frame = useRef<HTMLIFrameElement>(null);
  const loads = useRef(0);
  const [reported, setReported] = useState(INLINE_PREVIEW_MIN_HEIGHT);
  // One nonce per frame: a new document is a new frame (keyed by its text in Markdown.tsx).
  const [nonce] = useState(previewNonce);
  const srcDoc = useMemo(
    () => inlinePreviewDocument(kind, code, renderFrameCSS(), passive ? nonce : undefined),
    [kind, code, passive, nonce],
  );
  useEffect(() => {
    const onMessage = (event: MessageEvent) => {
      if (!frame.current?.contentWindow || event.source !== frame.current.contentWindow) return;
      const height = reportedHeight(event.data, INLINE_PREVIEW_EXPANDED_MAX_HEIGHT);
      if (height !== undefined) setReported(height);
    };
    addEventListener("message", onMessage);
    return () => removeEventListener("message", onMessage);
  }, []);
  useEffect(() => onHeight(reported), [onHeight, reported]);
  return (
    <iframe
      ref={frame}
      className="acpmux-render-card-frame"
      srcDoc={srcDoc}
      onLoad={() => {
        loads.current += 1;
        if (loads.current > 1) onLeave();
      }}
      title={title}
      sandbox={INLINE_PREVIEW_SANDBOX}
      referrerPolicy="no-referrer"
      style={{ height: Math.min(reported, max) }}
    />
  );
}

/// A run document in the native artifact frame, which reports its height as a render frame does.
function NativeFrame({ code, max, onHeight }: { code: string; max: number; onHeight(height: number): void }) {
  const t = useT();
  const { frame, height } = useRenderFrame(code);
  useEffect(() => onHeight(height), [onHeight, height]);
  return (
    <iframe
      ref={frame}
      className="acpmux-render-card-frame"
      src={artifactFrameURL()}
      title={languageLabel("html", t)}
      sandbox={INLINE_PREVIEW_SANDBOX}
      referrerPolicy="no-referrer"
      style={{ height: Math.min(height, max) }}
    />
  );
}
