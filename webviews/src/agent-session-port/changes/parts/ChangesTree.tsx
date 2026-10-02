// Changed-file tree (@pierre/trees). The filter field sits in Pierre's header slot; the
// tree holds exactly the matching paths (model.resetPaths on each edit, all folders open),
// so zero matches leaves an empty tree under "No matching files". Pierre's own search is
// not used because with no match it shows every row instead of none. Choosing a file
// reports it so the pane can scroll the diff list to it.
import type { Ref } from "react";
import { useMemo } from "react";
import { FileTree, useFileTree } from "@pierre/trees-port/react";
import type { FileTreeRowDecorationRenderer } from "@pierre/trees-port";
import { useStableCallback } from "@pierre/diffs-port/react";
import { codexColors } from "../theme";
import { treeUnsafeCSS } from "../treeStyles";
import { TREE_EMPTY_TEXT } from "../constants";
import * as I from "../icons";
import type { ChangedFile } from "../model";

/** Case-insensitive substring match on the full path. */
export const matchesFilter = (path: string, filter: string) => path.toLowerCase().includes(filter.trim().toLowerCase());

/** Every folder above `paths`, so a reset tree opens fully like the initial one. */
function folders(paths: readonly string[]) {
  const out = new Set<string>();
  for (const p of paths) for (let i = p.indexOf("/"); i > 0; i = p.indexOf("/", i + 1)) out.add(p.slice(0, i + 1));
  return [...out];
}

export function ChangesTree({
  files,
  selectedPath,
  filter,
  filterRef,
  onFilter,
  onSelect,
}: {
  files: readonly ChangedFile[];
  selectedPath: string | null;
  filter: string;
  /** The filter input, for "Jump to file". */
  filterRef?: Ref<HTMLInputElement>;
  onFilter: (value: string) => void;
  onSelect: (path: string) => void;
}) {
  const byPath = useMemo(() => new Map(files.map((f) => [f.path, f])), [files]);
  // +N -M in the decoration lane of each file row.
  const renderRowDecoration: FileTreeRowDecorationRenderer = ({ item }) => {
    const f = byPath.get(item.path);
    if (!f || item.kind !== "file") return null;
    const parts: { text: string; color: string }[] = [];
    if (f.additions > 0) parts.push({ text: `+${f.additions}`, color: codexColors.addition });
    if (f.deletions > 0) parts.push({ text: `-${f.deletions}`, color: codexColors.deletion });
    return { text: parts.map((p) => p.text).join(""), parts };
  };
  // Pierre reports selection from clicks and keyboard; only file rows map to a diff.
  const onSelectionChange = useStableCallback((paths: readonly string[]) => {
    const path = paths[paths.length - 1];
    if (path && byPath.has(path) && path !== selectedPath) onSelect(path);
  });
  // useFileTree creates the model once; later prop changes go through its methods.
  const { model } = useFileTree({
    paths: files.map((f) => f.path).filter((p) => matchesFilter(p, filter)),
    flattenEmptyDirectories: true,
    initialExpansion: "open",
    initialSelectedPaths: selectedPath ? [selectedPath] : [],
    onSelectionChange,
    icons: { set: "complete", colored: true },
    itemHeight: 29,
    renderRowDecoration,
    unsafeCSS: treeUnsafeCSS,
  });
  const empty = !files.some((f) => matchesFilter(f.path, filter));
  return (
    <FileTree
      model={model}
      className="cx-tree-host"
      header={
        <>
          <label className="cx-filter">
            <I.Search className="cx-filter-icon" width={14} height={14} />
            <input
              ref={filterRef}
              placeholder="Filter files..."
              aria-label="Filter files"
              value={filter}
              onChange={(e) => {
                const next = files.map((f) => f.path).filter((p) => matchesFilter(p, e.target.value));
                model.resetPaths(next, { initialExpandedPaths: folders(next) });
                onFilter(e.target.value);
              }}
            />
          </label>
          {/* Pierre has no empty-state slot; with zero rows the header is all it draws. */}
          {empty && <div className="cx-tree-empty">{TREE_EMPTY_TEXT}</div>}
        </>
      }
    />
  );
}
