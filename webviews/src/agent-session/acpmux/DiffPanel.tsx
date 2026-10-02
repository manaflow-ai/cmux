// The changes one turn made, after the Codex Changes pane in manaflow-ai/codex-atlas-clone
// (src/changes/parts/Header.tsx, DiffList.tsx and ChangesTree.tsx): a pill with the totals,
// a round toolbar, stacked per-file diffs on @pierre/diffs with a custom file header, and a
// filterable @pierre/trees file tree.
import React, { useEffect, useMemo, useRef, useState } from "react";
import { getFiletypeFromFileName, getSingularPatch, setLanguageOverride } from "@pierre/diffs";
import { FileDiff, useStableCallback } from "@pierre/diffs/react";
import { FileTree, useFileTree } from "@pierre/trees/react";
import type { FileTreeRowDecorationRenderer } from "@pierre/trees";
import { editPatch, type DiffEdit, type TurnFile } from "./diff";
import { isHighlighted } from "./shikiLanguages";
import {
  AGENT_DIFF_THEME,
  AGENT_DIFF_THEME_LIGHT,
  diffUnsafeCSS,
  registerAgentDiffTheme,
  treeUnsafeCSS,
} from "./diffTheme";
import {
  ChevronDown,
  ChevronLeft,
  CollapseAll,
  Eye,
  FileTypeIcon,
  Panels,
  Search,
  SplitView,
  Wrap,
} from "./changeIcons";

export type DiffLayout = "unified" | "split";

const LAYOUT_KEY = "cmux.acpmux.diffLayout";
const WRAP_KEY = "cmux.acpmux.diffWrap";
const TREE_KEY = "cmux.acpmux.diffTree";

/// The reader's view choices last as long as this pane's storage allows.
function stored(key: string): string | null {
  try {
    return window.localStorage?.getItem(key) ?? null;
  } catch {
    return null;
  }
}
function store(key: string, value: string) {
  try {
    window.localStorage?.setItem(key, value);
  } catch {
    /* the choice lasts this pane only */
  }
}

export function Counts({ additions, deletions }: { additions: number; deletions: number }) {
  return (
    <span className="acpmux-diff-counts">
      <span className="acpmux-diff-add">+{additions}</span>
      <span className="acpmux-diff-del">-{deletions}</span>
    </span>
  );
}

type FileView = { collapsed: boolean; viewed: boolean };
type FileActions = { toggleCollapsed: (path: string) => void; toggleViewed: (path: string) => void };

function FileHeader({
  file,
  edit,
  index,
  view,
  on,
}: {
  file: TurnFile;
  edit: DiffEdit;
  index: number;
  view: FileView;
  on: FileActions;
}) {
  const slash = file.displayPath.lastIndexOf("/");
  const additions = edit.hunks.reduce((sum, hunk) => sum + hunk.lines.filter((line) => line.type === "add").length, 0);
  const deletions = edit.hunks.reduce((sum, hunk) => sum + hunk.lines.filter((line) => line.type === "del").length, 0);
  return (
    <div className="acpmux-file-header" data-viewed={view.viewed ? "" : undefined}>
      <FileTypeIcon path={file.displayPath} />
      <button
        type="button"
        className="acpmux-fh-name"
        title={file.path}
        aria-expanded={!view.collapsed}
        onClick={() => on.toggleCollapsed(file.path)}
      >
        {slash >= 0 && <span className="acpmux-fh-dir">{file.displayPath.slice(0, slash + 1)}</span>}
        <span>{file.displayPath.slice(slash + 1)}</span>
        <ChevronDown className="acpmux-fh-chevron" width={14} height={14} />
      </button>
      {file.created && index === 0 && <span className="acpmux-fh-badge">New</span>}
      {file.edits.length > 1 && <span className="acpmux-fh-badge">{`Edit ${index + 1} of ${file.edits.length}`}</span>}
      <span className="acpmux-fh-spacer" />
      <Counts additions={additions} deletions={deletions} />
      <button
        type="button"
        className="acpmux-fh-btn"
        aria-label={view.viewed ? `Mark ${file.displayPath} as not viewed` : `Mark ${file.displayPath} as viewed`}
        aria-pressed={view.viewed}
        onClick={() => on.toggleViewed(file.path)}
      >
        <Eye />
      </button>
    </div>
  );
}

/// The pane's theme (applyAgentTheme) is light or dark; syntax colors follow it.
const paneThemeType = () =>
  document.documentElement.dataset.theme === "light" ? ("light" as const) : ("dark" as const);

function EditBlock({
  file,
  edit,
  index,
  layout,
  wrap,
  view,
  on,
  onPainted,
}: {
  file: TurnFile;
  edit: DiffEdit;
  index: number;
  layout: DiffLayout;
  wrap: boolean;
  view: FileView;
  on: FileActions;
  onPainted: () => void;
}) {
  // A language the bundle can't highlight shows as plain text; Pierre throws for it otherwise.
  // Each transcript update rebuilds the turn's files; the patch text is compared so an
  // unchanged edit keeps its parsed diff and does not paint again.
  const patch = useMemo(() => editPatch(file, edit), [file, edit]);
  const highlighted = isHighlighted(getFiletypeFromFileName(file.displayPath));
  const fileDiff = useMemo(() => {
    const parsed = getSingularPatch(patch);
    return highlighted ? parsed : setLanguageOverride(parsed, "text");
  }, [patch, highlighted]);
  const afterRender = useStableCallback(onPainted);
  const options = useMemo(
    () => ({
      theme: { dark: AGENT_DIFF_THEME, light: AGENT_DIFF_THEME_LIGHT },
      themeType: paneThemeType(),
      diffStyle: layout,
      diffIndicators: "bars" as const,
      hunkSeparators: "line-info" as const,
      lineDiffType: "none" as const,
      overflow: wrap ? ("wrap" as const) : ("scroll" as const),
      // A fragment edit has no known place in its file, so its numbers would be made up.
      disableLineNumbers: !edit.numbered,
      // The bundled page allows no WebAssembly.
      preferredHighlighter: "shiki-js" as const,
      disableFileHeader: true,
      unsafeCSS: diffUnsafeCSS,
      onPostRender: afterRender,
    }),
    [layout, wrap, edit.numbered, afterRender],
  );
  // The header sits outside Pierre's diff, so collapsing or marking a file keeps the same
  // header node and the button the reader pressed keeps focus.
  const header = <FileHeader file={file} edit={edit} index={index} view={view} on={on} />;
  const showDiff = !view.collapsed && edit.hunks.length > 0;
  return (
    <div className="acpmux-diff-file" data-path={file.path} data-collapsed={view.collapsed ? "" : undefined}>
      {header}
      {!view.collapsed && edit.hunks.length === 0 && <div className="acpmux-diff-empty-edit">No line changes</div>}
      {showDiff && <FileDiff className="acpmux-diff-pierre" fileDiff={fileDiff} options={options} />}
    </div>
  );
}

function ChangedFilesTree({
  files,
  selected,
  onSelect,
}: {
  files: TurnFile[];
  selected?: string;
  onSelect: (path: string) => void;
}) {
  const byDisplay = useMemo(() => new Map(files.map((file) => [file.displayPath, file])), [files]);
  // The tree keeps the renderer it was built with; it reads the current files through a ref.
  const filesRef = useRef(byDisplay);
  filesRef.current = byDisplay;
  const renderRowDecoration: FileTreeRowDecorationRenderer = ({ item }) => {
    const file = filesRef.current.get(item.path);
    if (!file || item.kind !== "file") return null;
    // This Pierre draws a decoration's text only, so the counts take the tree's muted color.
    const text = [file.additions > 0 && `+${file.additions}`, file.deletions > 0 && `-${file.deletions}`]
      .filter(Boolean)
      .join(" ");
    return text ? { text } : null;
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
    icons: { set: "complete", colored: true },
    itemHeight: 28,
    renderRowDecoration,
    unsafeCSS: treeUnsafeCSS,
  });
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
          aria-label="Filter files"
          placeholder="Filter files…"
          // Uncontrolled and read on each native input event (typing, paste, the clear button),
          // so filtering does not depend on React's change-event emulation.
          defaultValue=""
          onInput={(event) => setFilter(event.currentTarget.value)}
        />
      </label>
      {displayPaths.length === 0 && <div className="acpmux-diff-tree-empty">No matching files</div>}
      <FileTree model={model} className="acpmux-diff-tree-host" onClick={onRowPick} onKeyDown={onRowPick} />
    </>
  );
}

type Tool = "collapse" | "wrap" | "split" | "tree";

/// The changes one turn's tool calls made, file by file. Read-only; Back or Escape returns
/// to the transcript.
export function DiffPanel({
  files,
  initialPath,
  onClose,
}: {
  files: TurnFile[];
  initialPath?: string;
  onClose: () => void;
}) {
  registerAgentDiffTheme();
  const [layout, setLayout] = useState<DiffLayout>(() => (stored(LAYOUT_KEY) === "split" ? "split" : "unified"));
  const [wrap, setWrap] = useState(() => stored(WRAP_KEY) === "on");
  const [showTree, setShowTree] = useState(() => stored(TREE_KEY) !== "off");
  const [collapsed, setCollapsed] = useState<ReadonlySet<string>>(() => new Set());
  const [viewed, setViewed] = useState<ReadonlySet<string>>(() => new Set());
  const [selected, setSelected] = useState(initialPath ?? files[0]?.path);
  const body = useRef<HTMLDivElement>(null);
  const back = useRef<HTMLButtonElement>(null);
  const totals = useMemo(
    () =>
      files.reduce(
        (sum, file) => ({ additions: sum.additions + file.additions, deletions: sum.deletions + file.deletions }),
        { additions: 0, deletions: 0 },
      ),
    [files],
  );
  const reveal = (path: string) => {
    setSelected(path);
    const section = [...(body.current?.querySelectorAll<HTMLElement>(".acpmux-diff-file") ?? [])].find(
      (node) => node.dataset.path === path,
    );
    section?.scrollIntoView?.({ block: "start" });
  };
  // Diffs paint after the highlighter loads, moving the file below them; the opened file is
  // revealed again after each paint until the reader scrolls, types or picks another file.
  const revealing = useRef(initialPath);
  const stopRevealing = () => {
    revealing.current = undefined;
  };
  const revealFromTree = (path: string) => {
    revealing.current = path;
    // A file picked in the tree opens if it was collapsed.
    setCollapsed((current) => {
      if (!current.has(path)) return current;
      const next = new Set(current);
      next.delete(path);
      return next;
    });
    reveal(path);
  };
  // Wheel, pointer or key input in the diffs means the reader is moving on their own.
  useEffect(() => {
    const node = body.current;
    if (!node) return;
    const stop = () => {
      revealing.current = undefined;
    };
    for (const type of ["wheel", "pointerdown", "keydown"]) node.addEventListener(type, stop, { passive: true });
    return () => {
      for (const type of ["wheel", "pointerdown", "keydown"]) node.removeEventListener(type, stop);
    };
  }, []);
  const onPainted = useStableCallback(() => {
    if (revealing.current) reveal(revealing.current);
  });
  // Focus moves into the view, so keys reach it and a screen reader announces it.
  useEffect(() => {
    back.current?.focus();
    if (initialPath) reveal(initialPath);
  }, [initialPath]);
  // Escape closes the view while focus is in it (or nowhere), not while typing in the composer
  // or the file filter.
  const panel = useRef<HTMLElement>(null);
  useEffect(() => {
    const close = (event: KeyboardEvent) => {
      const focus = document.activeElement;
      if (event.key !== "Escape" || focus instanceof HTMLInputElement) return;
      if (!focus || focus === document.body || panel.current?.contains(focus)) onClose();
    };
    window.addEventListener("keydown", close);
    return () => window.removeEventListener("keydown", close);
  }, [onClose]);
  const on = useMemo<FileActions>(
    () => ({
      toggleCollapsed: (path) => {
        revealing.current = undefined;
        setCollapsed((current) => {
          const next = new Set(current);
          if (next.has(path)) next.delete(path);
          else next.add(path);
          return next;
        });
      },
      // Marking a file viewed folds it away, as in Codex; unmarking opens it again.
      toggleViewed: (path) => {
        revealing.current = undefined;
        const marking = !viewed.has(path);
        const flip = (current: ReadonlySet<string>) => {
          const next = new Set(current);
          if (marking) next.add(path);
          else next.delete(path);
          return next;
        };
        setViewed(flip);
        setCollapsed(flip);
      },
    }),
    [viewed],
  );
  const allCollapsed = files.length > 0 && files.every((file) => collapsed.has(file.path));
  const press = (tool: Tool) => {
    stopRevealing();
    if (tool === "collapse") setCollapsed(allCollapsed ? new Set() : new Set(files.map((file) => file.path)));
    else if (tool === "wrap") {
      setWrap(!wrap);
      store(WRAP_KEY, wrap ? "off" : "on");
    } else if (tool === "split") {
      const next = layout === "split" ? "unified" : "split";
      setLayout(next);
      store(LAYOUT_KEY, next);
    } else {
      setShowTree(!showTree);
      store(TREE_KEY, showTree ? "off" : "on");
    }
  };
  const tools: { id: Tool; label: string; icon: React.ReactNode; pressed: boolean }[] = [
    {
      id: "collapse",
      label: allCollapsed ? "Expand all files" : "Collapse all files",
      icon: <CollapseAll />,
      pressed: allCollapsed,
    },
    { id: "wrap", label: "Wrap lines", icon: <Wrap />, pressed: wrap },
    { id: "split", label: "Split view", icon: <SplitView />, pressed: layout === "split" },
    { id: "tree", label: "File tree", icon: <Panels />, pressed: showTree },
  ];
  return (
    <section ref={panel} className="acpmux-diff-panel" aria-label="Changes">
      <header className="acpmux-diff-header">
        <button ref={back} type="button" className="acpmux-diff-back" aria-label="Back to transcript" onClick={onClose}>
          <ChevronLeft />
        </button>
        <div className="acpmux-diff-scope">
          <strong>{files.length === 1 ? "1 file changed" : `${files.length} files changed`}</strong>
          <Counts additions={totals.additions} deletions={totals.deletions} />
        </div>
        <div className="acpmux-diff-tools" role="toolbar" aria-label="Changes view">
          {tools.map((tool) => (
            <button
              key={tool.id}
              type="button"
              className="acpmux-diff-tool"
              data-tool={tool.id}
              aria-label={tool.label}
              title={tool.label}
              aria-pressed={tool.pressed}
              onClick={() => press(tool.id)}
            >
              {tool.icon}
            </button>
          ))}
        </div>
      </header>
      <div className="acpmux-diff-main">
        <div ref={body} className="acpmux-diff-body">
          {files.length === 0 ? (
            <div className="acpmux-muted">No file changes in this turn.</div>
          ) : (
            files.flatMap((file) =>
              file.edits.map((edit, index) => (
                <EditBlock
                  key={`${file.path}\u0000${edit.toolId}\u0000${index}`}
                  file={file}
                  edit={edit}
                  index={index}
                  layout={layout}
                  wrap={wrap}
                  view={{ collapsed: collapsed.has(file.path), viewed: viewed.has(file.path) }}
                  on={on}
                  onPainted={onPainted}
                />
              )),
            )
          )}
        </div>
        {showTree && (
          <nav className="acpmux-diff-tree" aria-label="Changed files">
            <ChangedFilesTree files={files} selected={selected} onSelect={revealFromTree} />
          </nav>
        )}
      </div>
    </section>
  );
}
