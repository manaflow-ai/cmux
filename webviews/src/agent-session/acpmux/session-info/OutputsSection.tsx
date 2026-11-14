// Session Info's Outputs: what the chat itself made, as Claude Code desktop lists them, each row with a
// kind tag on the right and each opening what it names. Its artifacts (the pages its render calls
// showed and the HTML, SVG and Markdown documents its replies drew, each by its title, which open in
// the side panel beside the chat, ArtifactPanel.tsx), its gallery (the images and renders, which
// open GalleryDialog.tsx), and the files it made for the person (chatOutputs.ts; each opens as the reply's path chip opens it).
// First, the pull requests, issues and commits it produced (producedLinks.ts: opened, merged, filed,
// pushed), each a link glyph and a short label ("PR #923", "#7395", a short sha), opening the App's
// GitHub page or github.com (pullRequestDiff.ts `openOnGitHub`): a coding chat's work is what it
// published, so it leads (Leo, 2026-11-07, "at least do what [the reference] has here with outputs").
// Never the web links its replies gave:
// those are pages it read or cited, not things it made (Lucas, 2026-11-05: "outputs should be images,
// files, ect generate directly through that chat"). Five rows show, then a whole-row Show more
// (SessionInfoFold), as under Changes and Subagents.
import type { Artifact } from "../conversation/artifactPreview";
import type { OutputFile } from "./chatOutputs";
import { producedLabel, type ProducedLink } from "./producedLinks";
import { FileKindIcon } from "../chips/FileKindIcon";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";

import { useState, type ReactNode } from "react";
import { heightAbove, useFoldMotion } from "./foldMotion";
import { SessionInfoFold } from "./SessionInfoSection";
import { useScrollEdges } from "../summary/scrollEdges";
import "./outputsEdge.css";
import { OUTPUTS_SHOWN, type OutputArtifact } from "./outputsSectionModel";
import { WindowedRows } from "./WindowedRows";

const ROW_ICON = rowIconSize(12);
/// One thing the chat produced: a link glyph, its short label, and its repository's name when it is not
/// the chat folder's (the session works across repositories; "#12" alone would not say which).
export function ProducedRow({
  link,
  repository,
  onOpen,
}: {
  link: ProducedLink;
  /// The chat folder's `owner/name`.
  repository?: string;
  onOpen?: (url: string) => void;
}) {
  const t = useT();
  const other = repository?.toLowerCase() !== link.repo.toLowerCase();
  const content = (
    <>
      <Icon name="link" size={ROW_ICON} row />
      <span className="acpmux-session-info-row__name">
        {producedLabel(link, (n) => t("sessionInfo.outputs.pullRequest", { n }))}
      </span>
      {other && <span className="acpmux-session-info-row__detail">{link.repo.split("/")[1]}</span>}
    </>
  );
  return onOpen ? (
    <button
      type="button"
      className="acpmux-session-info-row acpmux-session-info-row--button"
      title={link.url}
      onClick={() => onOpen(link.url)}
    >
      {content}
    </button>
  ) : (
    <div className="acpmux-session-info-row" title={link.url}>
      {content}
    </div>
  );
}

export function OutputsSection({
  produced = [],
  repository,
  onOpenProduced,
  files,
  artifacts,
  documents = [],
  onOpenFile,
  onOpenArtifacts,
  onOpenDocument,
}: {
  /// The pull requests, issues and commits the chat produced (producedLinks.ts).
  produced?: readonly ProducedLink[];
  /// The chat folder's `owner/name`.
  repository?: string;
  /// Opens a produced row's GitHub page (pullRequestDiff.ts `openOnGitHub`).
  onOpenProduced?: (url: string) => void;
  /// The files the chat made for the person (chatOutputs.ts), never its code edits.
  files: readonly OutputFile[];
  /// How many images and renders the gallery holds.
  artifacts: number;
  /// The documents the chat produced (`outputArtifacts`).
  documents?: readonly OutputArtifact[];
  onOpenFile?: (path: string) => void;
  onOpenArtifacts?: () => void;
  /// Opens a document in the side panel beside the chat.
  onOpenDocument?: (artifact: Artifact) => void;
}) {
  const t = useT();
  const [all, setAll] = useState(false);
  const rows: ReactNode[] = [
    ...produced.map((link) => (
      <li key={link.key}>
        <ProducedRow link={link} repository={repository} onOpen={onOpenProduced} />
      </li>
    )),
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
          <FileKindIcon path={file.path} size={ROW_ICON} className="acpmux-row-glyph" />
          <span className="acpmux-session-info-row__name">{name}</span>
          {folder && <span className="acpmux-session-info-row__detail">{folder}</span>}
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
  ];
  const folds = rows.length - OUTPUTS_SHOWN >= 2;
  // Show more grows the list in place and Show less closes it over the rows that go (foldMotion.ts).
  const fold = useFoldMotion<HTMLDivElement>(all, (box) =>
    heightAbove(box, box.querySelector("ul")?.children[OUTPUTS_SHOWN]),
  );
  // Reuse the shared passive scroll/resize tracking; the ref removes it on unmount.
  const scrollEdges = useScrollEdges();
  return (
    <>
      <div ref={fold.ref} className="acpmux-outputs-edges">
        {/* Unfolded, the list scrolls past about eight rows, its edges faded (outputsEdge.css). */}
        <ul ref={scrollEdges} className="acpmux-session-info-list acpmux-session-info-scroll" data-section="outputs">
          <WindowedRows items={folds && !fold.drawn ? rows.slice(0, OUTPUTS_SHOWN) : rows} render={(row) => row} />
        </ul>
      </div>
      {folds && (
        <SessionInfoFold open={all} onToggle={() => fold.toggle(!all, setAll)}>
          {all ? t("sessionInfo.outputs.showLess") : t("sessionInfo.list.showMore", { n: rows.length - OUTPUTS_SHOWN })}
        </SessionInfoFold>
      )}
    </>
  );
}
