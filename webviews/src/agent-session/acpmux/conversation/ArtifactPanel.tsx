// The side panel beside the chat (cx-ncc.63, Claude parity): a document a reply carries in a fence
// (artifactPreview.ts) drawn as it renders, with its source on the Code tab. HTML and SVG draw in the
// render frame (RenderCard.tsx), an origin of its own that allows no connection, so a document cannot
// reach the pane, its bridge, acpmux or the network; Markdown draws as the transcript draws it. The
// pane on a dev server has no render frame, so there HTML and SVG show their source only.
import { useState } from "react";
import { useT } from "../i18n";
import { previewHtml, type Artifact } from "./artifactPreview";
import { copyText } from "./clipboard";
import { CodeBlock, languageLabel } from "./CodeBlock";
import { Close, Copy } from "./icons";
import { Markdown } from "./Markdown";
import { canRender, RENDER_FRAME_URL, useRenderFrame } from "./RenderCard";

export { OpenPreview } from "./OpenPreview";

export function ArtifactPanel({ artifact, onClose }: { artifact: Artifact; onClose(): void }) {
  const t = useT();
  const previews = artifact.kind === "markdown" || canRender();
  const [tab, setTab] = useState<"preview" | "code">(previews ? "preview" : "code");
  const [copied, setCopied] = useState(false);
  const title = languageLabel(artifact.lang, t);
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
          <CodeBlock code={artifact.code} lang={artifact.lang} />
        ) : artifact.kind === "markdown" ? (
          <div className="acpmux-artifact-doc">
            <Markdown>{artifact.code}</Markdown>
          </div>
        ) : (
          <ArtifactFrame html={previewHtml(artifact)} title={title} />
        )}
      </div>
    </aside>
  );
}

function ArtifactFrame({ html, title }: { html: string; title: string }) {
  const { frame } = useRenderFrame(html);
  return (
    <iframe
      ref={frame}
      className="acpmux-artifact-frame"
      src={RENDER_FRAME_URL}
      title={title}
      sandbox="allow-scripts"
      referrerPolicy="no-referrer"
    />
  );
}
