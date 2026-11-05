// Session Info's Sources, drawn by the App (SourcesSection.tsx): what the chat read, five then View
// all N. A file in the chat's folder opens in a tab; a link opens beside the chat, and a pull
// request's menu also opens its diff (View diff).
import type { Translate } from "../../i18n";
import type { SummarySource, SummarySourceKind } from "../../summary/sessionSummary";
import { SOURCES_SHOWN, scopedPath } from "../SourcesSection";
import type { NativeInfoActions, NativeInfoRow, NativeInfoSection } from "./model";
import { nativeExternalUrl, safeExternalUrl } from "./links";
import { extraFolderName } from "../../extraFolders";
import { pullRequestDiffUrl } from "../pullRequestDiff";

const SYMBOLS: Record<SummarySourceKind, string> = {
  file: "doc.text",
  mcp: "puzzlepiece.extension",
  pullRequest: "arrow.triangle.pull",
  issue: "arrow.triangle.pull",
  url: "link",
  image: "photo",
};

export type SourcesInput = {
  sources: readonly SummarySource[];
  /// The folders the chat sees beside its own (acpmux `additionalDirectories`), listed first.
  folders?: readonly string[];
  /// The chat's folder: a file outside it does not open.
  cwd?: string;
  onOpenFile?: (path: string) => unknown;
  onOpenBeside?: (url: string) => void;
  failures?: Readonly<Record<string, string>>;
  /// Every source shows (`sessionInfoState.sourcesAll`).
  expanded: boolean;
  onExpandedChange: (expanded: boolean) => void;
  /// The section is unfolded (`sections.sources`).
  open: boolean;
};

export function sourcesSection(
  input: SourcesInput,
  actions: NativeInfoActions,
  t: Translate,
): NativeInfoSection | undefined {
  const { sources, cwd, onOpenFile, onOpenBeside, expanded, onExpandedChange } = input;
  const openUrl = nativeExternalUrl(onOpenBeside);
  const folders = input.folders ?? [];
  if (sources.length + folders.length === 0) return undefined;
  const folds = sources.length > SOURCES_SHOWN;
  const shown = folds && !expanded ? sources.slice(0, SOURCES_SHOWN) : sources;
  const folderRows = folders.map((folder): NativeInfoRow => ({
    id: `folder:${folder}`,
    symbol: "folder",
    title: extraFolderName(folder),
    help: folder,
  }));
  const sourceRows = shown.map((source): NativeInfoRow => {
    const path = source.kind === "file" ? scopedPath(source.label, cwd) : undefined;
    const failure = path ? input.failures?.[path] : undefined;
    const row: NativeInfoRow = {
      id: source.image ? `image:${source.image.id}` : `${source.kind}:${source.url ?? source.label}`,
      symbol: SYMBOLS[source.kind ?? "url"],
      title: source.label || t("image.viewer"),
      ...(failure ? { subtitle: failure, tone: "failed" as const, help: failure } : {}),
    };
    if (path && onOpenFile && !failure)
      return {
        ...row,
        ...(failure ? {} : { help: path }),
        action: actions.add(`sources.openFile:${path}`, () => onOpenFile(path)),
      };
    const url = source.url;
    const diffUrl = source.kind === "pullRequest" ? pullRequestDiffUrl(url) : undefined;
    if (source.kind !== "file" && url && safeExternalUrl(url))
      return {
        ...row,
        help: url,
        action: actions.add(`sources.open:${url}`, () => openUrl(url)),
        ...(diffUrl
          ? {
              menu: [
                {
                  label: t("sessionInfo.changes.viewDiff"),
                  action: actions.add(`sources.viewDiff:${url}`, () => openUrl(diffUrl)),
                },
              ],
              menuLabel: t("sessionInfo.changes.more", { reference: source.label }),
            }
          : {}),
      };
    return row;
  });
  return {
    id: "sources",
    group: "made",
    title: t("summary.sources"),
    meta: String(sources.length + folders.length),
    open: input.open,
    foldable: true,
    reorderable: true,
    rows: [...folderRows, ...sourceRows],
    ...(folds
      ? {
          more: {
            label: expanded ? t("summary.showFewer") : t("summary.viewAll", { n: sources.length }),
            action: actions.add("sources.more", () => onExpandedChange(!expanded)),
          },
        }
      : {}),
  };
}
