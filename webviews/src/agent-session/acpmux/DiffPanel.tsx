import React, { useEffect, useMemo, useRef, useState } from "react";
import { fileTree, splitRows, type DiffEdit, type FileTreeNode, type TurnFile } from "./diff";

export type DiffLayout = "unified" | "split";

const LAYOUT_KEY = "cmux.acpmux.diffLayout";

function storedLayout(): DiffLayout {
  try { return window.localStorage?.getItem(LAYOUT_KEY) === "split" ? "split" : "unified"; } catch { return "unified"; }
}

function Stats({ additions, deletions }: { additions: number; deletions: number }) {
  return <span className="acpmux-diff-stats"><span className="acpmux-diff-added">+{additions}</span> <span className="acpmux-diff-removed">−{deletions}</span></span>;
}

function TreeNodes({ nodes, depth, selected, onSelect }: { nodes: FileTreeNode[]; depth: number; selected?: string; onSelect: (path: string) => void }) {
  return <>{nodes.map((node) => node.file
    ? <button key={node.path} type="button" aria-current={selected === node.file.path ? "true" : undefined} className="acpmux-diff-tree-file" style={{ paddingLeft: 8 + depth * 12 }} title={node.file.displayPath} onClick={() => onSelect(node.file!.path)}><span className="acpmux-diff-tree-name">{node.name}</span><Stats additions={node.file.additions} deletions={node.file.deletions} /></button>
    : <div key={node.path}><div className="acpmux-diff-tree-dir" style={{ paddingLeft: 8 + depth * 12 }}>{node.name}</div><TreeNodes nodes={node.children} depth={depth + 1} selected={selected} onSelect={onSelect} /></div>)}</>;
}

const lineNumber = (edit: DiffEdit, line: number | undefined) => edit.numbered && line !== undefined ? line : "";
const marker = (type: string) => type === "add" ? "+" : type === "del" ? "−" : " ";

function UnifiedEdit({ edit }: { edit: DiffEdit }) {
  return <>{edit.hunks.map((hunk, hunkIndex) => <tbody key={hunkIndex} className="acpmux-diff-hunk">{hunk.lines.map((line, index) => <tr key={index} className={`acpmux-diff-line acpmux-diff-${line.type}`}>
    <td className="acpmux-diff-num">{lineNumber(edit, line.oldLine)}</td>
    <td className="acpmux-diff-num">{lineNumber(edit, line.newLine)}</td>
    <td className="acpmux-diff-code"><span className="acpmux-diff-marker" aria-hidden="true">{marker(line.type)}</span>{line.text}</td>
  </tr>)}</tbody>)}</>;
}

function SplitEdit({ edit }: { edit: DiffEdit }) {
  return <>{edit.hunks.map((hunk, hunkIndex) => <tbody key={hunkIndex} className="acpmux-diff-hunk">{splitRows(hunk).map((row, index) => <tr key={index} className="acpmux-diff-line">
    <td className="acpmux-diff-num">{lineNumber(edit, row.left.line)}</td>
    <td className={`acpmux-diff-code acpmux-diff-${row.left.type}`}><span className="acpmux-diff-marker" aria-hidden="true">{row.left.type === "empty" ? "" : marker(row.left.type)}</span>{row.left.text}</td>
    <td className="acpmux-diff-num">{lineNumber(edit, row.right.line)}</td>
    <td className={`acpmux-diff-code acpmux-diff-${row.right.type}`}><span className="acpmux-diff-marker" aria-hidden="true">{row.right.type === "empty" ? "" : marker(row.right.type)}</span>{row.right.text}</td>
  </tr>)}</tbody>)}</>;
}

function FileSection({ file, layout }: { file: TurnFile; layout: DiffLayout }) {
  return <section className="acpmux-diff-file" data-path={file.path} aria-label={file.displayPath}>
    <header className="acpmux-diff-file-header"><span className="acpmux-diff-file-path">{file.displayPath}</span>{file.created && <span className="acpmux-diff-badge">new</span>}<Stats additions={file.additions} deletions={file.deletions} /></header>
    {file.edits.map((edit, index) => <table key={`${edit.toolId}-${index}`} className={`acpmux-diff-table acpmux-diff-${layout}`}>{layout === "split" ? <SplitEdit edit={edit} /> : <UnifiedEdit edit={edit} />}</table>)}
  </section>;
}

/// The changes one turn's tool calls made, file by file: a file tree beside the diffs,
/// unified or side by side. Read-only; it closes back to the transcript.
export function DiffPanel({ files, initialPath, onClose }: { files: TurnFile[]; initialPath?: string; onClose: () => void }) {
  const [layout, setLayout] = useState<DiffLayout>(storedLayout);
  const [selected, setSelected] = useState(initialPath ?? files[0]?.path);
  const body = useRef<HTMLDivElement>(null);
  const tree = useMemo(() => fileTree(files), [files]);
  const totals = useMemo(() => files.reduce((sum, file) => ({ additions: sum.additions + file.additions, deletions: sum.deletions + file.deletions }), { additions: 0, deletions: 0 }), [files]);
  const reveal = (path: string) => {
    setSelected(path);
    const section = [...(body.current?.querySelectorAll<HTMLElement>(".acpmux-diff-file") ?? [])].find((node) => node.dataset.path === path);
    section?.scrollIntoView?.({ block: "start" });
  };
  useEffect(() => { if (initialPath) reveal(initialPath); }, [initialPath]);
  const chooseLayout = (next: DiffLayout) => { setLayout(next); try { window.localStorage?.setItem(LAYOUT_KEY, next); } catch { /* the choice lasts this pane only */ } };
  useEffect(() => {
    const close = (event: KeyboardEvent) => { if (event.key === "Escape") onClose(); };
    window.addEventListener("keydown", close);
    return () => window.removeEventListener("keydown", close);
  }, [onClose]);
  return <section className="acpmux-diff-panel" aria-label="Changes">
    <header className="acpmux-diff-header">
      <button type="button" className="acpmux-diff-close" aria-label="Back to transcript" onClick={onClose}>‹</button>
      <strong>{files.length === 1 ? "1 file changed" : `${files.length} files changed`}</strong>
      <Stats additions={totals.additions} deletions={totals.deletions} />
      <div className="acpmux-diff-layout" aria-label="Diff layout">
        {(["unified", "split"] as const).map((option) => <button key={option} type="button" aria-pressed={layout === option} onClick={() => chooseLayout(option)}>{option === "unified" ? "Unified" : "Split"}</button>)}
      </div>
    </header>
    <div className="acpmux-diff-main">
      <nav className="acpmux-diff-tree" aria-label="Changed files"><TreeNodes nodes={tree} depth={0} selected={selected} onSelect={reveal} /></nav>
      <div ref={body} className="acpmux-diff-body">{files.length === 0 ? <div className="acpmux-muted">No file changes in this turn.</div> : files.map((file) => <FileSection key={file.path} file={file} layout={layout} />)}</div>
    </div>
  </section>;
}
