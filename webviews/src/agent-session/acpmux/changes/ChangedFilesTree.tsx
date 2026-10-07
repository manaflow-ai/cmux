// The changes view's filterable file tree, on @pierre/trees.
import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useStableCallback } from "@pierre/diffs/react";
import { FileTree, useFileTree } from "@pierre/trees/react";
import type { FileTreeRowDecorationRenderer } from "@pierre/trees";
import { createTextMeasure, diffStatSpriteSheet, fileTreeStatsDecoration } from "../../../file-tree-stats";
import type { TurnFile } from "../diff";
import { treeUnsafeCSS } from "../diffTheme";
import { Search } from "../changeIcons";
import { useT } from "../i18n";
import { experimentArm } from "../../../experiments/experiment";
import { diffTreeDisclosure, TREE_NAME_FADES, treeNameFade } from "./treeMotion.experiment";
import { attachTreeMotion } from "./treeMotionDom";
import { attachTreeTitles } from "./treeTitles";

export function ChangedFilesTree({
  files,
  selected,
  onSelect,
}: {
  files: TurnFile[];
  selected?: string;
  onSelect: (path: string) => void;
}) {
  const t = useT();
  // The folder disclosure motion and the long-name fade (the experiments' arms; their defaults ship).
  const disclosure = experimentArm(diffTreeDisclosure);
  const fadeWidth = TREE_NAME_FADES[experimentArm(treeNameFade)];
  const motionRef = useCallback(
    (node: HTMLDivElement | null) => {
      if (!node) return;
      const detachMotion = attachTreeMotion(node, disclosure);
      const detachTitles = attachTreeTitles(node, { fadeWidth });
      return () => {
        detachMotion();
        detachTitles();
      };
    },
    [disclosure, fadeWidth],
  );
  const byDisplay = useMemo(() => new Map(files.map((file) => [file.displayPath, file])), [files]);
  // The tree keeps the renderer it was built with; it reads the current files through a ref.
  const filesRef = useRef(byDisplay);
  filesRef.current = byDisplay;
  const [measureStats] = useState(() =>
    createTextMeasure('system-ui, -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif'),
  );
  const statsSpriteSheet = useMemo(
    () =>
      diffStatSpriteSheet(
        files.map((file) => ({ added: file.additions, deleted: file.deletions })),
        measureStats,
      ),
    [files, measureStats],
  );
  const renderRowDecoration: FileTreeRowDecorationRenderer = ({ item }) => {
    const file = filesRef.current.get(item.path);
    if (!file || item.kind !== "file") return null;
    return fileTreeStatsDecoration(
      { added: file.additions, deleted: file.deletions },
      { additions: "+", deletions: "-" },
      measureStats,
    );
  };
  // Pierre reports selection from clicks and keys; only file rows map to a diff.
  const onSelectionChange = useStableCallback((paths: readonly string[]) => {
    const file = filesRef.current.get(paths[paths.length - 1] ?? "");
    if (file && file.path !== selected) onSelect(file.path);
  });
  // Pierre reports no change when the selected row is picked again, but that file may have
  // been collapsed or scrolled away since, so a plain click, Enter or Space reveals it. A
  // modified click changes the selection only.
  const onRowPick = (event: React.MouseEvent | React.KeyboardEvent) => {
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    if ("key" in event && event.key !== "Enter" && event.key !== " ") return;
    const row = event.nativeEvent
      .composedPath()
      .find((node): node is HTMLElement => node instanceof HTMLElement && node.dataset.itemPath !== undefined);
    const file = row && filesRef.current.get(row.dataset.itemPath!);
    if (file && file.path === selected) onSelect(file.path);
  };
  const [filter, setFilter] = useState("");
  const displayPaths = useMemo(() => {
    const query = filter.trim().toLowerCase();
    return files.map((file) => file.displayPath).filter((path) => !query || path.toLowerCase().includes(query));
  }, [files, filter]);
  const selectedDisplay = files.find((file) => file.path === selected)?.displayPath;
  // useFileTree builds its model once; later changes go through the model.
  const { model } = useFileTree({
    paths: displayPaths,
    flattenEmptyDirectories: true,
    initialExpansion: "open",
    initialSelectedPaths: selectedDisplay ? [selectedDisplay] : [],
    onSelectionChange,
    icons: {
      set: "complete",
      colored: true,
      spriteSheet: statsSpriteSheet,
    },
    itemHeight: 28,
    renderRowDecoration,
    unsafeCSS: treeUnsafeCSS,
  });
  useEffect(() => {
    model.setIcons({ set: "complete", colored: true, spriteSheet: statsSpriteSheet });
  }, [model, statsSpriteSheet]);
  // A transcript update rebuilds the files; the tree resets only when the paths differ.
  const shown = useRef(displayPaths);
  useEffect(() => {
    if (shown.current.length === displayPaths.length && shown.current.every((path, i) => path === displayPaths[i]))
      return;
    shown.current = displayPaths;
    model.resetPaths(displayPaths);
  }, [model, displayPaths]);
  return (
    <>
      <label className="acpmux-diff-filter">
        <Search width={14} height={14} />
        <input
          type="search"
          aria-label={t("changes.filterFiles")}
          placeholder={t("changes.filterPlaceholder")}
          // Uncontrolled and read on each native input event (typing, paste, the clear button),
          // so filtering does not depend on React's change-event emulation.
          defaultValue=""
          onInput={(event) => setFilter(event.currentTarget.value)}
        />
      </label>
      {displayPaths.length === 0 && <div className="acpmux-diff-tree-empty">{t("changes.noMatchingFiles")}</div>}
      <div className="acpmux-diff-tree-motion" ref={motionRef}>
        <FileTree model={model} className="acpmux-diff-tree-host" onClick={onRowPick} onKeyDown={onRowPick} />
      </div>
    </>
  );
}
