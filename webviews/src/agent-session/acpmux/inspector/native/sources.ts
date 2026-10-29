// Session Info's Sources, drawn by the App (SourcesSection.tsx): what the chat read, five then View
// all N. A file in the chat's folder opens in a tab; a link opens beside the chat.
import type { Translate } from "../../i18n";
import type { SummarySource, SummarySourceKind } from "../../summary/sessionSummary";
import { SOURCES_SHOWN, scopedPath } from "../SourcesSection";
import type { NativeInfoActions, NativeInfoRow, NativeInfoSection } from "./model";

const SYMBOLS: Record<SummarySourceKind, string> = {
  file: "doc.text",
  mcp: "puzzlepiece.extension",
  pullRequest: "arrow.triangle.pull",
  issue: "arrow.triangle.pull",
  url: "link",
};

export type SourcesInput = {
  sources: readonly SummarySource[];
  /// The chat's folder: a file outside it does not open.
  cwd?: string;
  onOpenFile?: (path: string) => unknown;
  onOpenBeside?: (url: string) => void;
  /// Every source shows (`inspectorState.sourcesAll`).
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
  if (sources.length === 0) return undefined;
  const folds = sources.length > SOURCES_SHOWN;
  const shown = folds && !expanded ? sources.slice(0, SOURCES_SHOWN) : sources;
  const rows = shown.map((source): NativeInfoRow => {
    const row: NativeInfoRow = {
      id: `${source.kind}:${source.url ?? source.label}`,
      symbol: SYMBOLS[source.kind ?? "url"],
      title: source.label,
    };
    const path = source.kind === "file" ? scopedPath(source.label, cwd) : undefined;
    if (path && onOpenFile)
      return { ...row, help: path, action: actions.add(`sources.openFile:${path}`, () => onOpenFile(path)) };
    const url = source.url;
    if (source.kind !== "file" && url)
      return {
        ...row,
        help: url,
        ...(onOpenBeside ? { action: actions.add(`sources.open:${url}`, () => onOpenBeside(url)) } : {}),
      };
    return row;
  });
  return {
    id: "sources",
    group: "made",
    title: t("summary.sources"),
    meta: String(sources.length),
    open: input.open,
    foldable: true,
    rows,
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
