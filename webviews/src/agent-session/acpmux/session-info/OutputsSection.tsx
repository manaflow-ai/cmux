// Session Info's Outputs: what the chat itself made, as Claude Code desktop lists them, each row with a
// kind tag on the right and each opening what it names. Its artifacts (the pages its render calls
// showed and the HTML, SVG and Markdown documents its replies drew, each by its title, which open in
// the side panel beside the chat, ArtifactPanel.tsx), its gallery (the images and renders, which
// open GalleryDialog.tsx), and the files it made for the person (chatOutputs.ts; each opens as the reply's path chip opens it). Never the web links its replies gave:
// those are pages it read or cited, not things it made (Lucas, 2026-11-05: "outputs should be images,
// files, ect generate directly through that chat"). Five rows show, then a whole-row Show more
// (SessionInfoFold), as under Changes and Subagents.
import { documentName, type Artifact } from "../conversation/artifactPreview";
import { latestWrittenArtifacts } from "../conversation/writtenArtifacts";
import { chatDocuments } from "../conversation/artifactVersions";
import { renderPages } from "../conversation/renderCall";
import type { OutputFile } from "./chatOutputs";
import { FileKindIcon } from "../chips/FileKindIcon";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import type { AcpmuxRow } from "../model";
import { useState, type ReactNode } from "react";
import { SessionInfoFold } from "./SessionInfoSection";
import { useScrollEdges } from "../summary/scrollEdges";
import "./outputsEdge.css";

const ROW_ICON = rowIconSize(12);
/// Rows shown before Show more. A fold that would hold back one row shows it instead: "Show 1 more"
/// costs the row it saves (Lucas, 2026-11-05, Session Info lab: "output should be fold at 5").
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
  // Each file once, as its last completed write (not the last row that wrote it).
  for (const [path, { artifact }] of latestWrittenArtifacts(rows))
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
  artifacts,
  documents = [],
  onOpenFile,
  onOpenArtifacts,
  onOpenDocument,
}: {
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
  // Reuse the shared passive scroll/resize tracking; the ref removes it on unmount.
  const scrollEdges = useScrollEdges();
  return (
    <>
      <div className="acpmux-outputs-edges">
        {/* Unfolded, the list scrolls past about eight rows, its edges faded (outputsEdge.css). */}
        <ul ref={scrollEdges} className="acpmux-session-info-list acpmux-session-info-scroll" data-section="outputs">
          {folds && !all ? rows.slice(0, OUTPUTS_SHOWN) : rows}
        </ul>
      </div>
      {folds && (
        <SessionInfoFold open={all} onToggle={() => setAll(!all)}>
          {all ? t("sessionInfo.outputs.showLess") : t("sessionInfo.list.showMore", { n: rows.length - OUTPUTS_SHOWN })}
        </SessionInfoFold>
      )}
    </>
  );
}

/// A page the pane beside the chat can open: http(s) on localhost or 127.0.0.1 with no user info,
/// the rule the host's preview applies (URL+AgentPanePreview.swift).
export function opensBeside(url: string): boolean {
  try {
    const parsed = new URL(url);
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") return false;
    if (parsed.username || parsed.password) return false;
    return parsed.hostname === "localhost" || parsed.hostname === "127.0.0.1";
  } catch {
    return false;
  }
}
