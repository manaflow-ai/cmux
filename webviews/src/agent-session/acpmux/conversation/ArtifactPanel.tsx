// The side panel beside the chat (cx-ncc.63, Claude parity): a document a reply carries in a fence
// (artifactPreview.ts) drawn as it renders, with its source on the Code tab. HTML and SVG draw in the
// render frame (RenderCard.tsx), an origin of its own that allows no connection, so a document cannot
// reach the pane, its bridge, acpmux or the network; Markdown draws as the transcript draws it. The
// pane on a dev server shows source only unless liveRender supplies its srcdoc frame.
import { useContext, useEffect, useState } from "react";
import { ChatSessionContext, useRenderAttachment } from "./viewIdentity";
import { renderExecutionKey } from "./renderExecution";
import { useT } from "../i18n";
import { useLab } from "../labs";
import { isReactRender, REACT_MARKER } from "./renderFrameDoc";
import { documentName, previewHtml, type Artifact, type ArtifactKind } from "./artifactPreview";
import { copyText } from "./clipboard";
import { CodeBlock, languageLabel } from "./CodeBlock";
import { Check, ChevronLeft, ChevronRight, Close, Copy, SaveTray } from "./icons";
import { Markdown } from "./Markdown";
import { canRender, ranRenders, RenderCard, renderTitle, RENDER_FRAME_URL, useRenderFrame } from "./RenderCard";

export { OpenPreview } from "./OpenPreview";

/// Saves a document through the host's save panel (`pane.saveFile`): "saved", "cancelled" when the user
/// dismissed the panel (or one is already up), "unavailable" when no host could write it; the panel
/// then copies the document instead, as the inspector's Export does.
export type SaveDocument = (
  text: string,
  suggestedName: string,
  kind: ArtifactKind,
) => Promise<"saved" | "cancelled" | "unavailable">;

export function ArtifactPanel({
  artifact: opened,
  versions = [opened],
  onClose,
  onSave,
}: {
  artifact: Artifact;
  /// The document's versions in the chat (cx-ncc.64, `artifactVersions`), with the opened one: the
  /// header steps between them.
  versions?: readonly Artifact[];
  onClose(): void;
  /// Unset where the page has no host save panel (a gallery, a test): no Save.
  onSave?: SaveDocument;
}) {
  const t = useT();
  const live = useLab("liveRender");
  // The shown version by its text, not its place: a reply that finishes or a reload moves the list.
  const [shown, setShown] = useState(opened.code);
  // A shown version that left the list falls back to the opened one's place, then to it alone.
  const at = (code: string) => versions.findIndex((version) => version.code === code);
  const found = at(shown) >= 0 ? at(shown) : at(opened.code);
  const list = found >= 0 ? versions : [opened];
  const index = Math.max(0, found);
  const artifact = list[index]!;
  const previews = artifact.kind === "markdown" || canRender() || live;
  const [tab, setTab] = useState<"preview" | "code">(previews ? "preview" : "code");
  const [copied, setCopied] = useState(false);
  const [saved, setSaved] = useState(false);
  const step = (to: number) => {
    setShown(list[to]!.code);
    setCopied(false);
    setSaved(false);
  };
  // "Copied" is a moment's confirmation, then the button reads Copy again.
  useEffect(() => {
    if (!copied) return;
    const timer = setTimeout(() => setCopied(false), 1500);
    return () => clearTimeout(timer);
  }, [copied]);
  // Closing hands focus back to what opened the panel (an Open button in the transcript): the panel
  // unmounts with focus inside it, which would otherwise drop to the page.
  useEffect(() => {
    const opener = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    return () => {
      const focused = document.activeElement;
      if (opener?.isConnected && (!focused || focused === document.body)) opener.focus({ preventScroll: true });
    };
  }, []);
  // The document's own name (its heading or <title>), else its language.
  const language = live && artifact.kind === "react" ? t("render.untitled") : languageLabel(artifact.lang, t);
  const title =
    (live && artifact.kind === "react"
      ? renderTitle(isReactRender(artifact.code) ? artifact.code : REACT_MARKER + "\n" + artifact.code)
      : documentName(artifact)) || language;
  return (
    // oxlint-disable-next-line jsx-a11y/no-noninteractive-element-interactions -- Escape closes the panel from its tabs, buttons or a focused frame's edge.
    <aside
      className="acpmux-artifact"
      aria-label={t("artifact.panel")}
      // ui-allow: Escape closes the panel from anywhere inside it
      onKeyDown={(event) => {
        if (event.key !== "Escape" || event.defaultPrevented) return;
        event.preventDefault();
        onClose();
      }}
    >
      <div className="acpmux-artifact-bar">
        <span className="acpmux-artifact-title">{title}</span>
        {list.length > 1 && (
          <span className="acpmux-artifact-versions">
            <button
              type="button"
              className="cv-iconbtn cv-iconbtn--compact"
              aria-label={t("artifact.previousVersion")}
              title={t("artifact.previousVersion")}
              disabled={index === 0}
              onClick={() => step(index - 1)}
            >
              <ChevronLeft size={14} />
            </button>
            <span className="acpmux-artifact-version">{`${index + 1}/${list.length}`}</span>
            <button
              type="button"
              className="cv-iconbtn cv-iconbtn--compact"
              aria-label={t("artifact.nextVersion")}
              title={t("artifact.nextVersion")}
              disabled={index === list.length - 1}
              onClick={() => step(index + 1)}
            >
              <ChevronRight size={14} />
            </button>
          </span>
        )}
        {previews && (
          <span className="acpmux-artifact-tabs">
            <button
              type="button"
              className="acpmux-artifact-tab"
              aria-label={t("artifact.preview")}
              aria-pressed={tab === "preview"}
              onClick={() => setTab("preview")}
            >
              {t("artifact.preview")}
            </button>
            <button
              type="button"
              className="acpmux-artifact-tab"
              aria-label={t("artifact.code")}
              aria-pressed={tab === "code"}
              onClick={() => setTab("code")}
            >
              {t("artifact.code")}
            </button>
          </span>
        )}
        <span className="acpmux-artifact-actions">
          <button
            type="button"
            className="cv-iconbtn cv-iconbtn--compact"
            aria-label={copied ? t("turn.copied") : t("turn.copy")}
            title={copied ? t("turn.copied") : t("turn.copy")}
            onClick={() => void copyText(artifact.code).then(() => setCopied(true))}
          >
            <Copy size={14} />
          </button>
          {onSave && (
            <button
              type="button"
              className="cv-iconbtn cv-iconbtn--compact"
              aria-label={saved ? t("artifact.saved") : t("artifact.save")}
              title={saved ? t("artifact.saved") : t("artifact.save")}
              onClick={() =>
                void onSave(artifact.code, documentName(artifact), artifact.kind)
                  // A host that failed to save is as good as none: copy the document instead.
                  .catch(() => "unavailable" as const)
                  .then((outcome) => {
                    setSaved(outcome === "saved");
                    if (outcome === "unavailable") void copyText(artifact.code).then(() => setCopied(true));
                  })
              }
            >
              {saved ? <Check size={14} /> : <SaveTray size={14} />}
            </button>
          )}
          <button
            type="button"
            className="cv-iconbtn cv-iconbtn--compact"
            aria-label={t("artifact.close")}
            title={t("artifact.close")}
            onClick={onClose}
          >
            <Close size={14} />
          </button>
        </span>
      </div>
      <div className="acpmux-artifact-body">
        {tab === "code" ? (
          <CodeBlock
            code={artifact.code}
            lang={artifact.lang}
            label={live && artifact.kind === "react" ? t("artifact.code") : undefined}
          />
        ) : artifact.kind === "markdown" ? (
          <div className="acpmux-artifact-doc">
            <Markdown>{artifact.code}</Markdown>
          </div>
        ) : live ? (
          <RenderCard
            key={artifact.code}
            panel
            call={{
              html:
                artifact.kind === "react" && !artifact.code.trimStart().startsWith(REACT_MARKER)
                  ? REACT_MARKER + "\n" + artifact.code
                  : previewHtml(artifact),
              title,
            }}
          />
        ) : (
          // Each version is its own frame: a frame draws the first document it is sent, and a
          // version with script waits for Run again.
          <ArtifactFrame key={artifact.code} html={previewHtml(artifact)} title={title} />
        )}
      </div>
    </aside>
  );
}

/// A document that can run script waits for Run, as a render card does: the frame shares the pane's
/// web process, so a busy loop would freeze the pane. Markup without script draws at once.
const runsScript = (code: string) => /<script\b|\son[a-z]+\s*=|javascript:/i.test(code);

function ArtifactFrame({ html, title }: { html: string; title: string }) {
  const t = useT();
  const session = useContext(ChatSessionContext);
  const attachment = useRenderAttachment();
  const key = renderExecutionKey(session, ["artifact", html], attachment);
  const [granted, setGranted] = useState<string>();
  const running = granted === key || ranRenders.has(key) || !runsScript(html);
  if (!running)
    return (
      <div className="acpmux-artifact-run">
        <button
          type="button"
          className="acpmux-review-changes"
          onClick={() => {
            ranRenders.add(key);
            setGranted(key);
          }}
        >
          {t("render.run")}
        </button>
      </div>
    );
  return <RunningFrame html={html} title={title} />;
}

function RunningFrame({ html, title }: { html: string; title: string }) {
  const { frame, stopped, error } = useRenderFrame(html);
  const t = useT();
  if (stopped)
    return (
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- the same note as the render card's.
      <div className="acpmux-render-note" role="status">
        {t("render.error")} {error}
      </div>
    );
  return (
    // oxlint-disable-next-line jsx-a11y/iframe-has-title -- aria-label names it; a title would float as a tooltip.
    <iframe
      ref={frame}
      className="acpmux-artifact-frame"
      src={RENDER_FRAME_URL}
      aria-label={title}
      sandbox="allow-scripts"
      referrerPolicy="no-referrer"
    />
  );
}
