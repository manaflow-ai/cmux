// Session Info's Outputs: what the chat produced, as Claude Code desktop lists them, each row with a
// kind tag on the right and each opening what it names. Its artifacts (the pages its render calls
// showed and the HTML, SVG and Markdown documents its replies drew, each by its title, which open in
// the side panel beside the chat, ArtifactPanel.tsx), its gallery (the images and renders, which
// open GalleryDialog.tsx), its files (each opens its diff), and the web links its replies gave, each
// once (a pull request's link is under Changes instead). Five rows show, then a whole-row Show more
// (SessionInfoFold), as under Changes and Subagents.
import { documentName, type Artifact } from "../conversation/artifactPreview";
import { writtenArtifacts } from "../conversation/writtenArtifacts";
import { chatDocuments } from "../conversation/artifactVersions";
import { renderPages } from "../conversation/renderCall";
import type { TurnFile } from "../diff";
import { Counts } from "../changes/Counts";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import type { AcpmuxRow } from "../model";
import { useState, type ReactNode } from "react";
import { SessionInfoFold } from "./SessionInfoSection";

const ROW_ICON = rowIconSize(12);
/// Rows shown before Show more, as Changes (`CHANGES_SHOWN`).
export const OUTPUTS_SHOWN = 5;
const LINK = /https?:\/\/[^\s"'<>)\]`]+/g;
const PULL_REQUEST = /^https:\/\/github\.com\/[\w.-]+\/[\w.-]+\/pull\/\d+/;

export type OutputLink = { readonly url: string; readonly label: string };
/// A document the chat produced, by its title when it has one.
export type OutputArtifact = {
  readonly key: string;
  readonly title?: string;
  readonly artifact: Artifact;
};

/// The chat's artifacts, oldest first: each render card's latest page (renderCall.ts `renderPages`;
/// its title, else its page's), then each document its finished replies drew, each text once.
export function outputArtifacts(rows: readonly AcpmuxRow[]): OutputArtifact[] {
  const found: OutputArtifact[] = [];
  const seen = new Set<string>();
  for (const page of new Set(renderPages(rows).values())) {
    const call = page.calls.at(-1)!;
    const artifact: Artifact = {
      kind: "html",
      lang: "html",
      code: call.html,
      render: page.first,
    };
    seen.add(call.html);
    found.push({
      key: `render:${page.first}`,
      title: call.title || documentName(artifact) || undefined,
      artifact,
    });
  }
  const replies = rows.flatMap((row) => (row.kind === "assistant" && !row.streaming && row.text ? [row.text] : []));
  for (const artifact of chatDocuments(replies)) {
    if (seen.has(artifact.code)) continue;
    seen.add(artifact.code);
    found.push({
      key: `document:${found.length}`,
      title: documentName(artifact) || undefined,
      artifact,
    });
  }
  const writes = new Map<string, Artifact>();
  for (const artifact of writtenArtifacts(rows)) writes.set(artifact.path!, artifact);
  for (const [path, artifact] of writes)
    found.push({
      key: `file:${path}`,
      title: documentName(artifact) || path.split("/").pop(),
      artifact,
    });
  return found;
}

/// Each reply's links, kept while the row is the same object (a streamed update replaces only the
/// live row).
const rowLinks = new WeakMap<AcpmuxRow, string[]>();

/// The web links the chat's replies gave, oldest first, each once; pull requests are left out.
export function outputLinks(rows: readonly AcpmuxRow[]): OutputLink[] {
  const seen = new Set<string>();
  const links: OutputLink[] = [];
  for (const row of rows) {
    if (row.kind !== "assistant" || !row.text) continue;
    let found = rowLinks.get(row);
    if (!found) rowLinks.set(row, (found = [...row.text.matchAll(LINK)].map(([url]) => url.replace(/[.,;:!?]+$/, ""))));
    for (const url of found) {
      if (seen.has(url) || PULL_REQUEST.test(url)) continue;
      seen.add(url);
      links.push({
        url,
        label: url.replace(/^https?:\/\/(www\.)?/, "").replace(/\/$/, ""),
      });
    }
  }
  return links;
}

export function OutputsSection({
  files,
  links,
  artifacts,
  documents = [],
  onOpenFile,
  onOpenArtifacts,
  onOpenDocument,
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
        <a className="acpmux-session-info-row acpmux-session-info-row--button" href={link.url}>
          <Icon name="link.web" size={ROW_ICON} row />
          <span className="acpmux-session-info-row__name">{link.label}</span>
          <span className="acpmux-session-info-row__end">{t("sessionInfo.outputs.link")}</span>
        </a>
      </li>
    )),
  ];
  const folds = rows.length > OUTPUTS_SHOWN;
  return (
    <>
      <ul className="acpmux-session-info-list acpmux-session-info-scroll" data-section="outputs">
        {folds && !all ? rows.slice(0, OUTPUTS_SHOWN) : rows}
      </ul>
      {folds && (
        <SessionInfoFold open={all} onToggle={() => setAll(!all)}>
          {t(all ? "sessionInfo.outputs.showLess" : "sessionInfo.outputs.showMore")}
        </SessionInfoFold>
      )}
    </>
  );
}
