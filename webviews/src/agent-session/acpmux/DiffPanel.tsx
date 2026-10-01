// The changes one turn made, after the Codex Changes pane in manaflow-ai/codex-atlas-clone
// (src/changes/parts/DiffList.tsx and ChangesTree.tsx): stacked per-file diffs on
// @pierre/diffs with a custom file header, beside a @pierre/trees file tree.
import React, { useEffect, useMemo, useRef, useState } from "react";
import { PatchDiff, useStableCallback } from "@pierre/diffs/react";
import { FileTree, useFileTree } from "@pierre/trees/react";
import type { FileTreeRowDecorationRenderer } from "@pierre/trees";
import { editPatch, type DiffEdit, type TurnFile } from "./diff";
import { AGENT_DIFF_THEME, diffColors, diffUnsafeCSS, registerAgentDiffTheme, treeUnsafeCSS } from "./diffTheme";

export type DiffLayout = "unified" | "split";

const LAYOUT_KEY = "cmux.acpmux.diffLayout";

function storedLayout(): DiffLayout {
  try { return window.localStorage?.getItem(LAYOUT_KEY) === "split" ? "split" : "unified"; } catch { return "unified"; }
}

function Counts({ additions, deletions }: { additions: number; deletions: number }) {
  return <span className="acpmux-diff-counts"><span className="acpmux-diff-add">+{additions}</span><span className="acpmux-diff-del">-{deletions}</span></span>;
}

function FileHeader({ file, edit, index }: { file: TurnFile; edit: DiffEdit; index: number }) {
  const slash = file.displayPath.lastIndexOf("/");
  const additions = edit.hunks.reduce((sum, hunk) => sum + hunk.lines.filter((line) => line.type === "add").length, 0);
  const deletions = edit.hunks.reduce((sum, hunk) => sum + hunk.lines.filter((line) => line.type === "del").length, 0);
  return <div className="acpmux-file-header">
    <span className="acpmux-fh-name" title={file.path}>{slash >= 0 && <span className="acpmux-fh-dir">{file.displayPath.slice(0, slash + 1)}</span>}<span>{file.displayPath.slice(slash + 1)}</span></span>
    {file.created && index === 0 && <span className="acpmux-fh-badge">New</span>}
    {file.edits.length > 1 && <span className="acpmux-fh-badge">{`Edit ${index + 1} of ${file.edits.length}`}</span>}
    <span className="acpmux-fh-spacer" />
    <Counts additions={additions} deletions={deletions} />
  </div>;
}

function EditBlock({ file, edit, index, layout }: { file: TurnFile; edit: DiffEdit; index: number; layout: DiffLayout }) {
  const patch = useMemo(() => editPatch(file, edit), [file, edit]);
  const options = useMemo(() => ({
    theme: AGENT_DIFF_THEME,
    themeType: "dark" as const,
    diffStyle: layout,
    diffIndicators: "bars" as const,
    hunkSeparators: "line-info" as const,
    lineDiffType: "none" as const,
    overflow: "scroll" as const,
    // A fragment edit has no known place in its file, so its numbers would be made up.
    disableLineNumbers: !edit.numbered,
    // The bundled page allows no WebAssembly.
    preferredHighlighter: "shiki-js" as const,
    unsafeCSS: diffUnsafeCSS,
  }), [layout, edit.numbered]);
  return <div className="acpmux-diff-file" data-path={file.path}>
    <PatchDiff className="acpmux-diff-pierre" patch={patch} options={options} renderCustomHeader={() => <FileHeader file={file} edit={edit} index={index} />} />
  </div>;
}

function ChangedFilesTree({ files, selected, onSelect }: { files: TurnFile[]; selected?: string; onSelect: (path: string) => void }) {
  const byDisplay = useMemo(() => new Map(files.map((file) => [file.displayPath, file])), [files]);
  const renderRowDecoration: FileTreeRowDecorationRenderer = ({ item }) => {
    const file = byDisplay.get(item.path);
    if (!file || item.kind !== "file") return null;
    const parts: { text: string; color: string }[] = [];
    if (file.additions > 0) parts.push({ text: `+${file.additions}`, color: diffColors.addition });
    if (file.deletions > 0) parts.push({ text: `-${file.deletions}`, color: diffColors.deletion });
    return { text: parts.map((part) => part.text).join(""), parts };
  };
  // Pierre reports selection from clicks and keys; only file rows map to a diff.
  const onSelectionChange = useStableCallback((paths: readonly string[]) => {
    const file = byDisplay.get(paths[paths.length - 1] ?? "");
    if (file && file.path !== selected) onSelect(file.path);
  });
  const displayPaths = useMemo(() => files.map((file) => file.displayPath), [files]);
  const selectedDisplay = files.find((file) => file.path === selected)?.displayPath;
  // useFileTree builds its model once; later changes go through the model.
  const { model } = useFileTree({
    paths: displayPaths,
    flattenEmptyDirectories: true,
    initialExpansion: "open",
    initialSelectedPaths: selectedDisplay ? [selectedDisplay] : [],
    onSelectionChange,
    icons: { set: "complete", colored: true },
    itemHeight: 29,
    renderRowDecoration,
    unsafeCSS: treeUnsafeCSS,
  });
  const shown = useRef(displayPaths);
  useEffect(() => {
    if (shown.current === displayPaths) return;
    shown.current = displayPaths;
    model.resetPaths(displayPaths);
  }, [model, displayPaths]);
  return <FileTree model={model} className="acpmux-diff-tree-host" />;
}

/// The changes one turn's tool calls made, file by file. Read-only; Back or Escape returns
/// to the transcript.
export function DiffPanel({ files, initialPath, onClose }: { files: TurnFile[]; initialPath?: string; onClose: () => void }) {
  registerAgentDiffTheme();
  const [layout, setLayout] = useState<DiffLayout>(storedLayout);
  const [selected, setSelected] = useState(initialPath ?? files[0]?.path);
  const body = useRef<HTMLDivElement>(null);
  const back = useRef<HTMLButtonElement>(null);
  const totals = useMemo(() => files.reduce((sum, file) => ({ additions: sum.additions + file.additions, deletions: sum.deletions + file.deletions }), { additions: 0, deletions: 0 }), [files]);
  const reveal = (path: string) => {
    setSelected(path);
    const section = [...(body.current?.querySelectorAll<HTMLElement>(".acpmux-diff-file") ?? [])].find((node) => node.dataset.path === path);
    section?.scrollIntoView?.({ block: "start" });
  };
  // Focus moves into the view, so keys reach it and a screen reader announces it.
  useEffect(() => { back.current?.focus(); if (initialPath) reveal(initialPath); }, [initialPath]);
  // Escape closes the view while focus is in it (or nowhere), not while typing in the composer.
  const panel = useRef<HTMLElement>(null);
  useEffect(() => {
    const close = (event: KeyboardEvent) => {
      const focus = document.activeElement;
      if (event.key === "Escape" && (!focus || focus === document.body || panel.current?.contains(focus))) onClose();
    };
    window.addEventListener("keydown", close);
    return () => window.removeEventListener("keydown", close);
  }, [onClose]);
  const chooseLayout = (next: DiffLayout) => { setLayout(next); try { window.localStorage?.setItem(LAYOUT_KEY, next); } catch { /* the choice lasts this pane only */ } };
  return <section ref={panel} className="acpmux-diff-panel" aria-label="Changes">
    <header className="acpmux-diff-header">
      <button ref={back} type="button" className="acpmux-diff-back" aria-label="Back to transcript" onClick={onClose}>‹</button>
      <strong>{files.length === 1 ? "1 file changed" : `${files.length} files changed`}</strong>
      <Counts additions={totals.additions} deletions={totals.deletions} />
      <div className="acpmux-diff-layout" aria-label="Diff layout">
        {(["unified", "split"] as const).map((option) => <button key={option} type="button" aria-pressed={layout === option} onClick={() => chooseLayout(option)}>{option === "unified" ? "Unified" : "Split"}</button>)}
      </div>
    </header>
    <div className="acpmux-diff-main">
      <div ref={body} className="acpmux-diff-body">{files.length === 0 ? <div className="acpmux-muted">No file changes in this turn.</div> : files.flatMap((file) => file.edits.map((edit, index) => <EditBlock key={`${file.path}\u0000${edit.toolId}\u0000${index}`} file={file} edit={edit} index={index} layout={layout} />))}</div>
      <nav className="acpmux-diff-tree" aria-label="Changed files"><ChangedFilesTree files={files} selected={selected} onSelect={reveal} /></nav>
    </div>
  </section>;
}
