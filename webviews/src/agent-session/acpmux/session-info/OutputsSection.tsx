// Session Info's Outputs: what the chat produced, as Claude Code desktop lists them, each row with a
// kind tag on the right and each opening what it names. Its artifacts (the pages its render calls
// showed and the HTML, SVG and Markdown documents its replies drew, each by its title, which open in
// the side panel beside the chat, ArtifactPanel.tsx), its gallery (the images and renders, which
// open GalleryDialog.tsx), its files (each opens its diff), and the web links its replies gave, each
// once (a pull request's link is under Changes instead). Five rows show, then a whole-row Show more
// (SessionInfoFold), as under Changes and Subagents.
import { type Artifact } from "../conversation/artifactPreview";

import type { TurnFile } from "../diff";
import { Counts } from "../changes/Counts";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";

import { useState, type ReactNode } from "react";
import { SessionInfoFold } from "./SessionInfoSection";
import { useScrollEdges } from "../summary/scrollEdges";
import "./outputsEdge.css";
import { OUTPUTS_SHOWN, type OutputLink, type OutputArtifact, opensBeside } from "./outputsSectionModel";

const ROW_ICON = rowIconSize(12);
export function OutputsSection({
  files,
  links,
  artifacts,
  documents = [],
  onOpenFile,
  onOpenArtifacts,
  onOpenDocument,
  onOpenBeside,
}: {
  files: readonly TurnFile[];
  links: readonly OutputLink[];
  /// How many images and renders the gallery holds.
  artifacts: number;
  /// The documents the chat produced (`outputArtifacts`).
  documents?: readonly OutputArtifact[];
  onOpenFile?: (path: string) => void;
  onOpenArtifacts?: () => void;
  /// Opens a document in the side panel beside the chat.
  onOpenDocument?: (artifact: Artifact) => void;
  /// Opens a link in the pane beside the chat, as Sources and Changes open theirs (SourcesSection.tsx);
  /// a modified click (⌘, ⌃, ⇧) keeps the link's own behaviour.
  onOpenBeside?: (url: string) => void;
}) {
  const t = useT();
  const [all, setAll] = useState(false);
  const rows: ReactNode[] = [
    ...(onOpenDocument
      ? documents.map((document) => (
          <li key={document.key}>
            <button
              type="button"
              className="acpmux-session-info-row acpmux-session-info-row--button"
              onClick={() => onOpenDocument(document.artifact)}
            >
              <Icon name={document.artifact.kind === "markdown" ? "file.text" : "code"} size={ROW_ICON} row />
              <span className="acpmux-session-info-row__name">{document.title ?? t("render.untitled")}</span>
              <span className="acpmux-session-info-row__end">{t("sessionInfo.outputs.artifact")}</span>
            </button>
          </li>
        ))
      : []),
    ...(artifacts > 0 && onOpenArtifacts
      ? [
          <li key="gallery">
            <button
              type="button"
              className="acpmux-session-info-row acpmux-session-info-row--button"
              onClick={onOpenArtifacts}
            >
              <Icon name="view.grid" size={ROW_ICON} row />
              <span className="acpmux-session-info-row__name">{t("summary.gallery")}</span>
              <span className="acpmux-session-info-row__end">{artifacts}</span>
            </button>
          </li>,
        ]
      : []),
    ...files.map((file) => {
      const cut = file.displayPath.lastIndexOf("/");
      const name = cut >= 0 ? file.displayPath.slice(cut + 1) : file.displayPath;
      const folder = cut > 0 ? file.displayPath.slice(0, cut) : undefined;
      const content = (
        <>
          <Icon name={file.created ? "file.new" : "file.text"} size={ROW_ICON} row />
          <span className="acpmux-session-info-row__name">{name}</span>
          {folder && <span className="acpmux-session-info-row__detail">{folder}</span>}
          {!file.binary && (
            <span className="acpmux-session-info-row__end">
              <Counts additions={file.additions} deletions={file.deletions} />
            </span>
          )}
        </>
      );
      return (
        <li key={file.path}>
          {onOpenFile ? (
            <button
              type="button"
              className="acpmux-session-info-row acpmux-session-info-row--button"
              onClick={() => onOpenFile(file.path)}
            >
              {content}
            </button>
          ) : (
            <div className="acpmux-session-info-row">{content}</div>
          )}
        </li>
      );
    }),
    ...links.map((link) => (
      <li key={link.url}>
        <a
          className="acpmux-session-info-row acpmux-session-info-row--button"
          href={link.url}
          onClick={(event) => {
            // The pane beside the chat opens only loopback pages (URL.isAgentPanePreview); any other
            // link, and a modified click (⌘, ⌃, ⇧), keeps the link's own behaviour.
            if (!onOpenBeside || !opensBeside(link.url) || event.metaKey || event.ctrlKey || event.shiftKey) return;
            event.preventDefault();
            onOpenBeside(link.url);
          }}
        >
          <Icon name="link.web" size={ROW_ICON} row />
          <span className="acpmux-session-info-row__name">{link.label}</span>
          <span className="acpmux-session-info-row__end">{t("sessionInfo.outputs.link")}</span>
        </a>
      </li>
    )),
  ];
  const folds = rows.length > OUTPUTS_SHOWN;
  // Reuse the shared passive scroll/resize tracking; the ref removes it on unmount.
  const scrollEdges = useScrollEdges();
  return (
    <>
      <div className="acpmux-outputs-edges">
        <ul ref={scrollEdges} className="acpmux-session-info-list acpmux-session-info-scroll" data-section="outputs">
          {folds && !all ? rows.slice(0, OUTPUTS_SHOWN) : rows}
        </ul>
      </div>
      {folds && (
        <SessionInfoFold open={all} onToggle={() => setAll(!all)}>
          {t(all ? "sessionInfo.outputs.showLess" : "sessionInfo.outputs.showMore")}
        </SessionInfoFold>
      )}
    </>
  );
}
