// The side panel beside the chat (cx-ncc.63, Claude parity): a document a reply carries in a fence
// (artifactPreview.ts) drawn as it renders, with its source on the Code tab. HTML and SVG draw in the
// offline artifact frame, an origin of its own that allows no connection, so a document cannot
// reach the pane, its bridge, acpmux or the network; passive markup draws in a scriptless srcdoc and
// waits for Run before the native frame grants scripts. Markdown draws as the transcript draws it.
// The gallery runs public fixtures in srcdoc; other dev pages show their source only.
import { useEffect, useState, useSyncExternalStore } from "react";
import { useT } from "../i18n";
import { artifactFileName, documentName, previewHtml, type Artifact, type ArtifactKind } from "./artifactPreview";
import {
  artifactCanRender,
  artifactFrameURL,
  artifactGallery,
  artifactNeedsRun,
  galleryArtifactDocument,
} from "./artifactSandbox";
import { renderFrameCSS } from "./renderBase";
import { copyText } from "./clipboard";
import { CodeBlock, languageLabel } from "./CodeBlock";
import { Check, ChevronLeft, ChevronRight, Close, Copy, SaveTray } from "./icons";
import { Markdown } from "./Markdown";
import { canRender, ranRenders, RENDER_FRAME_URL, useRenderFrame } from "./RenderCard";

export { OpenPreview } from "./OpenPreview";

/// Saves a document through the host's save panel (`pane.saveFile`): "saved", "cancelled" when the user
/// dismissed the panel (or one is already up), "unavailable" when no host could write it; the panel
/// then copies the document instead, as the inspector's Export does.
export type SaveDocument = (
  text: string,
  suggestedName: string,
  kind: ArtifactKind,
) => Promise<"saved" | "cancelled" | "unavailable">;

/// Below this pane width the side panel covers the whole pane instead of sitting beside the chat
/// (conversation.css `@media (max-width: 720px)`): the chat's header, and the Inspector's toggle in
/// it, are under it, so the Inspector steps aside while it is open (App.tsx `covered`).
export const ARTIFACT_COVERS_PANE = "(max-width: 720px)";
const subscribeCovers = (change: () => void) => {
  const query = globalThis.matchMedia?.(ARTIFACT_COVERS_PANE);
  query?.addEventListener("change", change);
  return () => query?.removeEventListener("change", change);
};
const coversNow = () => globalThis.matchMedia?.(ARTIFACT_COVERS_PANE).matches ?? false;
/// Whether an open side panel would cover the whole pane at its current width.
export const useArtifactCoversPane = (): boolean => useSyncExternalStore(subscribeCovers, coversNow, () => false);

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
  // The shown version by its text, not its place: a reply that finishes or a reload moves the list.
  const [shown, setShown] = useState(opened.code);
  // A shown version that left the list falls back to the opened one's place, then to it alone.
  const at = (code: string) => versions.findIndex((version) => version.code === code);
  const found = at(shown) >= 0 ? at(shown) : at(opened.code);
  const list = found >= 0 ? versions : [opened];
  const index = Math.max(0, found);
  const artifact = list[index]!;
  const jsx = /^(jsx|tsx)$/i.test(artifact.lang);
  const previews =
    artifact.kind === "markdown" || (artifact.render ? canRender() : artifactCanRender()) || artifactGallery();
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
  const language = languageLabel(artifact.lang, t);
  const title = documentName(artifact) || artifact.path?.split("/").pop() || language;
  return (
    // oxlint-disable-next-line jsx-a11y/no-noninteractive-element-interactions -- Escape closes the panel from its tabs, buttons or a focused frame's edge.
    <aside
      className="acpmux-artifact"
      // Slides in from the pane's right edge (ui/presence.ts).
      data-enter="right"
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
                void (async () => {
                  // JSX saves as a standalone offline HTML document; Copy keeps its original source.
                  const text = jsx
                    ? galleryArtifactDocument(
                        (await import("./artifactJsx")).jsxDocument(artifact.code),
                        renderFrameCSS(),
                      )
                    : artifact.code;
                  return onSave(text, artifactFileName(artifact), artifact.kind);
                })()
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
            onClick={onClose}
          >
            <Close size={14} />
          </button>
        </span>
      </div>
      <div className="acpmux-artifact-body">
        {tab === "code" || !previews ? (
          <CodeBlock code={artifact.code} lang={artifact.lang} />
        ) : artifact.kind === "markdown" ? (
          <div className="acpmux-artifact-doc">
            <Markdown>{artifact.code}</Markdown>
          </div>
        ) : (
          // Each version is its own frame: a frame draws the first document it is sent, and a
          // version with script waits for Run again.
          <ArtifactFrame
            key={artifact.code}
            html={previewHtml(artifact)}
            title={title}
            jsx={jsx}
            render={!!artifact.render}
          />
        )}
      </div>
    </aside>
  );
}

function ArtifactFrame({ html, title, jsx, render }: { html: string; title: string; jsx: boolean; render: boolean }) {
  const t = useT();
  const requiresRun = render || jsx || artifactNeedsRun(html);
  const [allowed, setAllowed] = useState(() => ranRenders.has(html));
  if (!requiresRun) return <PassiveFrame html={html} title={title} />;
  if (!allowed)
    return (
      <div className="acpmux-artifact-run">
        <button
          type="button"
          className="acpmux-review-changes"
          onClick={() => {
            ranRenders.add(html);
            setAllowed(true);
          }}
        >
          {t("render.run")}
        </button>
      </div>
    );
  return jsx ? (
    <JsxFrame code={html} title={title} render={render} />
  ) : (
    <RunningFrame html={html} title={title} render={render} />
  );
}

function PassiveFrame({ html, title }: { html: string; title: string }) {
  return (
    <iframe
      className="acpmux-artifact-frame"
      srcDoc={galleryArtifactDocument(html, renderFrameCSS())}
      title={title}
      sandbox=""
      referrerPolicy="no-referrer"
    />
  );
}

function JsxFrame({ code, title, render }: { code: string; title: string; render: boolean }) {
  const [html, setHtml] = useState<string>();
  const [failed, setFailed] = useState(false);
  useEffect(() => {
    let active = true;
    void import("./artifactJsx")
      .then(({ jsxDocument }) => {
        if (active) setHtml(jsxDocument(code));
      })
      .catch(() => {
        if (active) setFailed(true);
      });
    return () => {
      active = false;
    };
  }, [code]);
  if (failed) return <CodeBlock code={code} lang="jsx" />;
  return html === undefined ? null : <RunningFrame html={html} title={title} render={render} />;
}

function RunningFrame({ html, title, render }: { html: string; title: string; render: boolean }) {
  const { frame } = useRenderFrame(html);
  return (
    <iframe
      ref={frame}
      className="acpmux-artifact-frame"
      src={artifactGallery() ? undefined : render ? RENDER_FRAME_URL : artifactFrameURL()}
      srcDoc={artifactGallery() ? galleryArtifactDocument(html, renderFrameCSS()) : undefined}
      title={title}
      sandbox="allow-scripts"
      referrerPolicy="no-referrer"
    />
  );
}
