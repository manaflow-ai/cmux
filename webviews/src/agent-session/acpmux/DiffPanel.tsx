// The changes one turn made, ported from the changes pane in the agent-pane reference prototype
// (src/changes/parts/Header.tsx, DiffList.tsx and ChangesTree.tsx): a pill with the totals,
// a round toolbar, stacked per-file diffs on @pierre/diffs with a custom file header, and a
// filterable @pierre/trees file tree.
import React, { useEffect, useMemo, useRef, useState } from "react";
import { useStableCallback } from "@pierre/diffs/react";
import type { TurnFile } from "./diff";
import { registerAgentDiffTheme } from "./diffTheme";
import { ChevronLeft, CollapseAll, Panels, SplitView, Wrap } from "./changeIcons";
import { ChangedFilesTree } from "./changes/ChangedFilesTree";
import { Counts } from "./changes/Counts";
import { EditBlock, type DiffLayout } from "./changes/EditBlock";
import type { FileActions, OpenTarget } from "./changes/FileHeader";
import { LoadState } from "./changes/LoadState";
import { changeSetFiles, type ChangeScope, type ChangesSource } from "./changes/model";
import { ScopeMenu } from "./changes/ScopeMenu";
import { useScopeChanges } from "./changes/useScopeChanges";

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

type Tool = "collapse" | "wrap" | "split" | "tree";

/// The changes one turn's tool calls made, file by file, or a git scope of the session's
/// repository from `source`. Read-only; Back or Escape returns to the transcript.
export function DiffPanel({
  files: turnFiles,
  initialPath,
  onClose,
  source,
  onOpenFile,
  checkpointAction,
  checkpointReview,
}: {
  files: TurnFile[];
  initialPath?: string;
  onClose: () => void;
  source?: ChangesSource;
  /// Asks the host to open a changed file; rejects with the host's reason when it can't.
  onOpenFile?: (path: string, where: OpenTarget) => Promise<unknown>;
  checkpointAction?: React.ReactNode;
  checkpointReview?: React.ReactNode;
}) {
  registerAgentDiffTheme();
  const [scope, setScope] = useState<ChangeScope>("lastTurn");
  const { load, retry } = useScopeChanges(source, scope);
  const scopeFiles = useMemo(() => (load.state === "loaded" ? changeSetFiles(load.changeSet) : []), [load]);
  const files = scope === "lastTurn" ? turnFiles : scopeFiles;
  /// A git scope's body before its files: loading, failed or empty.
  const scopeState =
    scope === "lastTurn" || (load.state === "loaded" && files.length > 0)
      ? undefined
      : load.state === "loaded"
        ? "empty"
        : load.state;
  const [layout, setLayout] = useState<DiffLayout>(() => (stored(LAYOUT_KEY) === "split" ? "split" : "unified"));
  const [wrap, setWrap] = useState(() => stored(WRAP_KEY) === "on");
  const [showTree, setShowTree] = useState(() => stored(TREE_KEY) !== "off");
  const [collapsed, setCollapsed] = useState<ReadonlySet<string>>(() => new Set());
  const [viewed, setViewed] = useState<ReadonlySet<string>>(() => new Set());
  const [selected, setSelected] = useState<string | undefined>(initialPath ?? files[0]?.path);
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
  // Why the last open failed, until the next open or another scope. Only the latest open's
  // failure shows: an earlier one that fails late was overtaken.
  const [openFailure, setOpenFailure] = useState<string>();
  const latestOpen = useRef(0);
  const openFile = useStableCallback((path: string, where: OpenTarget) => {
    const request = ++latestOpen.current;
    setOpenFailure(undefined);
    const opening = onOpenFile ? onOpenFile(path, where) : Promise.reject(new Error("The file could not be opened."));
    opening.catch((error: unknown) => {
      if (request !== latestOpen.current) return;
      setOpenFailure(error instanceof Error && error.message ? error.message : "The file could not be opened.");
    });
  });
  const on = useMemo<FileActions>(
    () => ({
      openFile,
      toggleCollapsed: (path) => {
        revealing.current = undefined;
        setCollapsed((current) => {
          const next = new Set(current);
          if (next.has(path)) next.delete(path);
          else next.add(path);
          return next;
        });
      },
      // Marking a file viewed folds it away; unmarking opens it again.
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
    [viewed, openFile],
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
        <ScopeMenu
          scope={scope}
          onScope={(next) => {
            if (next === scope) return;
            // Another scope is other contents: its files start open, unviewed and unpicked.
            stopRevealing();
            setScope(next);
            setCollapsed(new Set());
            setViewed(new Set());
            setSelected(undefined);
            latestOpen.current += 1;
            setOpenFailure(undefined);
          }}
        >
          {files.length > 0 && <Counts additions={totals.additions} deletions={totals.deletions} />}
        </ScopeMenu>
        <div className="acpmux-diff-tools" role="toolbar" aria-label="Changes view">
          {checkpointAction}
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
      {openFailure && (
        <div className="acpmux-diff-notice" role="alert">
          {openFailure}
        </div>
      )}
      {checkpointReview}
      <div className="acpmux-diff-main">
        <div ref={body} className="acpmux-diff-body">
          {scopeState ? (
            <LoadState
              state={scopeState}
              onRetry={() => {
                // Retry leaves as the load starts, so focus moves to the scope pill.
                panel.current?.querySelector<HTMLElement>(".acpmux-diff-scope")?.focus();
                retry();
              }}
            />
          ) : files.length === 0 ? (
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
