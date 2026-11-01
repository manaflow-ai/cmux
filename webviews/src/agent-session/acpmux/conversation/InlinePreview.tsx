// A closed ```html or ```svg fence in a reply, drawn as the document it holds (leo-workspace
// design/artifacts.md). The preview is an iframe sandboxed with `allow-scripts` and no
// `allow-same-origin`, so the document is an opaque origin that cannot reach the pane. Only markup
// with no script (artifactNeedsRun) previews, made inert first (previewDocument.ts: no refresh, no
// resource hints, no outbound link). In the app it draws in the native artifact frame
// (`cmux-agent://render/artifact`, or the shared page host's), which has its own policy with no
// network, reports its height and whose host refuses its navigation; a `srcdoc` frame would take the
// pane's policy, which runs no inline script, so it could not report a height. The gallery, which has
// no native frame, draws it in `srcdoc` behind the artifact policy with a nonce'd frame script. Any
// other page shows the source. The height follows the frame's report, accepted only from that
// frame's window, capped at 480 px (Expand lifts the cap), and the document scrolls past it. A document that
// carries script stays the code card, whose Open puts it in the side panel, where Run is (#26216).
// Code shows the source card, which keeps Copy. Markdown.tsx draws this only once the fence has
// closed: an open fence stays plain code, so no frame is made or reloaded per token. The frame mounts
// once the card nears the viewport, so a long chat does not start every frame at once.
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
  inlinePreviewHtml,
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
  // The frame left its document (its frame counts its loads): the card shows the source.
  const [left, setLeft] = useState(false);
  const scripted = useMemo(() => artifactNeedsRun(code), [code]);
  // Only the native frame or the gallery can draw it; anywhere else (the dev server) shows the source.
  const framed = artifactFrameURL() !== undefined || artifactGallery();
  if (scripted || left || !framed) return <CodeBlock code={code} lang={lang} actions={actions} />;
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
  if (showCode)
    return (
      <CodeBlock
        code={code}
        lang={lang}
        actions={
          <>
            {toggle}
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
  expanded,
  onExpand,
  onLeave,
  head,
}: {
  kind: "html" | "svg";
  code: string;
  lang: string;
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
  return (
    <div ref={setCard} className="acpmux-render-card cv-inline-preview" data-kind={kind}>
      <div className="acpmux-render-card-head">
        <span className="acpmux-render-card-title">{languageLabel(lang, t)}</span>
        {height > INLINE_PREVIEW_MAX_HEIGHT && (
          <button type="button" className="acpmux-review-changes" aria-expanded={expanded} onClick={onExpand}>
            {expanded ? t("render.collapse") : t("render.expand")}
          </button>
        )}
        <span className="cv-codeblock__actions">{head}</span>
      </div>
      {near &&
        (artifactFrameURL() ? (
          <NativeFrame kind={kind} code={code} max={max} onHeight={setHeight} />
        ) : (
          <PreviewFrame kind={kind} code={code} max={max} onHeight={setHeight} onLeave={onLeave} />
        ))}
    </div>
  );
}

/// The inert document in the native artifact frame, which writes it into itself under its own policy
/// and reports its height (useRenderFrame, as the side panel's Run does).
function NativeFrame({
  kind,
  code,
  max,
  onHeight,
}: {
  kind: "html" | "svg";
  code: string;
  max: number;
  onHeight(height: number): void;
}) {
  const t = useT();
  const html = useMemo(() => inlinePreviewHtml(kind, code), [kind, code]);
  const { frame, height } = useRenderFrame(html);
  useEffect(() => onHeight(height), [onHeight, height]);
  return (
    <iframe
      ref={frame}
      className="acpmux-render-card-frame"
      src={artifactFrameURL()}
      title={languageLabel(kind, t)}
      sandbox={INLINE_PREVIEW_SANDBOX}
      referrerPolicy="no-referrer"
      style={{ height: Math.min(height, max) }}
    />
  );
}

/// The document in srcdoc (the gallery). The height listener takes only this frame's own messages. A second load
/// means the frame navigated away from its document (past the frame script's guards,
/// previewDocument.ts): whatever it loaded runs without the policy, so the frame goes and the card
/// shows the source.
function PreviewFrame({
  kind,
  code,
  max,
  onHeight,
  onLeave,
}: {
  kind: "html" | "svg";
  code: string;
  max: number;
  onHeight(height: number): void;
  onLeave(): void;
}) {
  const t = useT();
  const frame = useRef<HTMLIFrameElement>(null);
  const loads = useRef(0);
  const [reported, setReported] = useState(INLINE_PREVIEW_MIN_HEIGHT);
  // One nonce per frame: a new document is a new frame (keyed by its text in Markdown.tsx).
  const [nonce] = useState(previewNonce);
  const srcDoc = useMemo(() => inlinePreviewDocument(kind, code, renderFrameCSS(), nonce), [kind, code, nonce]);
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
      title={languageLabel(kind, t)}
      sandbox={INLINE_PREVIEW_SANDBOX}
      referrerPolicy="no-referrer"
      style={{ height: Math.min(reported, max) }}
    />
  );
}
