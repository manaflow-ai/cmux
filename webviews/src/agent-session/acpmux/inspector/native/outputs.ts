// Session Info's Outputs, drawn by the App (OutputsSection.tsx): the chat's documents (open in the
// side panel), its gallery, its files (each opens its diff) and the web links its replies gave.
import type { Translate } from "../../i18n";
import type { Artifact } from "../../conversation/artifactPreview";
import type { TurnFile } from "../../diff";
import type { OutputArtifact, OutputLink } from "../OutputsSection";
import type { NativeInfoActions, NativeInfoRow, NativeInfoSection } from "./model";

export type OutputsInput = {
  files: readonly TurnFile[];
  links: readonly OutputLink[];
  /// How many images and renders the gallery holds.
  artifacts: number;
  /// The documents the chat produced (`outputArtifacts`).
  documents?: readonly OutputArtifact[];
  onOpenFile?: (path: string) => void;
  onOpenArtifacts?: () => void;
  onOpenDocument?: (artifact: Artifact) => void;
  /// Opens a link (the web rows' `href`).
  onOpenUrl?: (url: string) => void;
  /// The section is unfolded (`sections.outputs`).
  open: boolean;
};

export function outputsSection(
  input: OutputsInput,
  actions: NativeInfoActions,
  t: Translate,
): NativeInfoSection | undefined {
  const { files, links, artifacts, documents = [], onOpenFile, onOpenArtifacts, onOpenDocument, onOpenUrl } = input;
  // As ChatInspector shows it: any file, link, gallery item, or document it can open.
  if (files.length + links.length + artifacts + (onOpenDocument ? documents.length : 0) === 0) return undefined;
  const rows: NativeInfoRow[] = [];
  if (onOpenDocument)
    for (const document of documents)
      rows.push({
        id: `document:${document.key}`,
        symbol: document.artifact.kind === "markdown" ? "doc.text" : "chevron.left.forwardslash.chevron.right",
        title: document.title ?? t("render.untitled"),
        trailing: t("chatInspector.outputs.artifact"),
        action: actions.add(`outputs.openDocument:${document.key}`, () => onOpenDocument(document.artifact)),
      });
  if (artifacts > 0 && onOpenArtifacts)
    rows.push({
      id: "gallery",
      symbol: "square.grid.2x2",
      title: t("summary.gallery"),
      trailing: String(artifacts),
      action: actions.add("outputs.openGallery", onOpenArtifacts),
    });
  for (const file of files) {
    const cut = file.displayPath.lastIndexOf("/");
    const folder = cut > 0 ? file.displayPath.slice(0, cut) : undefined;
    rows.push({
      id: `file:${file.path}`,
      symbol: file.created ? "doc.badge.plus" : "doc.text",
      title: cut >= 0 ? file.displayPath.slice(cut + 1) : file.displayPath,
      ...(folder ? { detail: folder } : {}),
      ...(file.binary ? {} : { trailing: `+${file.additions} -${file.deletions}` }),
      help: file.path,
      ...(onOpenFile ? { action: actions.add(`outputs.openFile:${file.path}`, () => onOpenFile(file.path)) } : {}),
    });
  }
  for (const link of links)
    rows.push({
      id: `link:${link.url}`,
      symbol: "link",
      title: link.label,
      trailing: t("chatInspector.outputs.link"),
      help: link.url,
      ...(onOpenUrl ? { action: actions.add(`outputs.openLink:${link.url}`, () => onOpenUrl(link.url)) } : {}),
    });
  return {
    id: "outputs",
    group: "made",
    title: t("rail.outputs"),
    open: input.open,
    foldable: true,
    rows,
  };
}
