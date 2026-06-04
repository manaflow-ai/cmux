import { CodeView, WorkerPoolContextProvider, type CodeViewHandle, useWorkerPool } from "@pierre/diffs/react";
import { getFiletypeFromFileName, parsePatchFiles, preloadHighlighter, processFile, registerCustomTheme } from "@pierre/diffs";
import { FileTree, useFileTree } from "@pierre/trees/react";
import { preparePresortedFileTreeInput } from "@pierre/trees";
import { useEffect, useReducer, useRef, useState } from "react";
import { copyGitApplyCommand, diffSourceDetail, resolveDiffNavigationURL } from "./actions";
import { resolveDiffViewerAppearance } from "./appearance";
import { fileName, type DiffItem, type FileTreeSource, type StreamMetrics, streamPatch } from "./diff-stream";
import { applyPierreFileTreeGitStatus, planPierreFileTreeRefresh, selectPierreFileTreePath } from "./file-tree-refresh";
import { Icon, type IconName } from "./icons";
import { createDiffViewerLabelResolver, shouldAssertMissingLabels } from "./labels";
import {
  codeViewOptions,
  fileTreeUnsafeCSS,
  shikiThemeFromGhostty,
  workerHighlighterOptions,
  type DiffViewerOptions,
} from "./pierre-options";
import { applyDiffViewerStatusToDocument, createDiffViewerStatus } from "./status";
import type { DiffViewerLabelResolver } from "./labels";
import type { DiffViewerStatus } from "./status";
import type { DiffViewerConfig } from "./types";
import { createDiffWorkerPoolOptions } from "./worker-pool";

type ConfigProps = {
  config: DiffViewerConfig;
  initialStatus: DiffViewerStatus;
};

type AppState = {
  activeItemId: string;
  activeTreePath: string;
  copyFeedback: string;
  fileSearchOpen: boolean;
  filesWidth: number;
  filesVisible: boolean;
  items: DiffItem[];
  metrics: StreamMetrics | null;
  options: DiffViewerOptions;
  optionsOpen: boolean;
  status: DiffViewerStatus;
  treeSource: FileTreeSource | null;
};

type AppAction =
  | { type: "append-items"; items: DiffItem[] }
  | { type: "rename-item"; oldId: string; newId: string }
  | { type: "set-active-item"; itemId: string; treePath?: string }
  | { type: "set-copy-feedback"; message: string }
  | { type: "set-file-search-open"; open: boolean }
  | { type: "set-files-width"; width: number }
  | { type: "set-files-visible"; visible: boolean }
  | { type: "set-metrics"; metrics: StreamMetrics }
  | { type: "set-option"; key: keyof DiffViewerOptions; value: any }
  | { type: "set-options-open"; open: boolean }
  | { type: "set-status"; status: DiffViewerStatus }
  | { type: "set-tree-source"; source: FileTreeSource };

const fileSkeletonWidths = ["82%", "64%", "76%", "58%", "70%", "46%"];
const diffSkeletonWidths = ["58%", "88%", "72%", "94%", "64%", "82%", "52%", "78%"];
const defaultWorkerModuleURL = "./assets/pierre-diffs-1.2.7-trees-1.0.0-beta.4/worker-pool/worker-portable.js";

function initialAppState(config: DiffViewerConfig, initialStatus: DiffViewerStatus): AppState {
  const payload = config.payload ?? {};
  return {
    activeItemId: "",
    activeTreePath: "",
    copyFeedback: "",
    fileSearchOpen: false,
    filesWidth: 252,
    filesVisible: true,
    items: [],
    metrics: null,
    options: {
      collapsed: false,
      diffIndicators: "bars",
      expandUnchanged: false,
      layout: payload.layout === "unified" ? "unified" : "split",
      lineNumbers: true,
      showBackgrounds: true,
      wordDiffs: false,
      wordWrap: false,
    } as DiffViewerOptions,
    optionsOpen: false,
    status: initialStatus,
    treeSource: null,
  };
}

function reducer(state: AppState, action: AppAction): AppState {
  switch (action.type) {
  case "append-items": {
    const nextItems = state.options.collapsed
      ? action.items.map((item) => ({ ...item, collapsed: true }))
      : action.items;
    return {
      ...state,
      activeItemId: state.activeItemId || nextItems[0]?.id || "",
      items: [...state.items, ...nextItems],
      status: state.status.loading ? createDiffViewerStatus("", { loading: false }) : state.status,
    };
  }
  case "rename-item":
    return {
      ...state,
      activeItemId: state.activeItemId === action.oldId ? action.newId : state.activeItemId,
      items: state.items.map((item) => (
        item.id === action.oldId || item.id === action.newId
          ? { ...item, id: action.newId, version: (item.version ?? 0) + 1 }
          : item
      )),
    };
  case "set-active-item":
    return {
      ...state,
      activeItemId: action.itemId,
      activeTreePath: action.treePath ?? state.activeTreePath,
    };
  case "set-copy-feedback":
    return { ...state, copyFeedback: action.message };
  case "set-file-search-open":
    return { ...state, fileSearchOpen: action.open, filesVisible: action.open ? true : state.filesVisible };
  case "set-files-width":
    return { ...state, filesWidth: action.width };
  case "set-files-visible":
    return { ...state, filesVisible: action.visible };
  case "set-metrics":
    return { ...state, metrics: action.metrics };
  case "set-option":
    if (action.key === "collapsed") {
      return {
        ...state,
        options: { ...state.options, collapsed: Boolean(action.value) },
        items: state.items.map((item) => ({
          ...item,
          collapsed: Boolean(action.value),
          version: (item.version ?? 0) + 1,
        })),
      };
    }
    return { ...state, options: { ...state.options, [action.key]: action.value } };
  case "set-options-open":
    return { ...state, optionsOpen: action.open };
  case "set-status":
    return { ...state, status: action.status };
  case "set-tree-source": {
    const source = action.source;
    const nextPath = state.activeItemId ? source.treePathByItemId.get(state.activeItemId) ?? state.activeTreePath : state.activeTreePath;
    return {
      ...state,
      activeTreePath: nextPath,
      treeSource: source,
    };
  }
  }
}

export function App({ config, initialStatus }: ConfigProps) {
  const payload = config.payload ?? {};
  const label = createDiffViewerLabelResolver(payload.labels, {
    assertMissing: shouldAssertMissingLabels(),
  });
  const appearance = resolveDiffViewerAppearance(payload.appearance);
  const [state, dispatch] = useReducer(reducer, initialAppState(config, initialStatus));
  const latestState = useSyncedRef(state);
  const codeViewRef = useRef<CodeViewHandle<any> | null>(null);
  const copyFallbackRef = useRef<HTMLTextAreaElement | null>(null);
  const viewerContainerRef = useRef<HTMLDivElement | null>(null);
  const workerModuleURL = resolveDiffViewerAssetURL(config.assets?.workerModuleURL);
  const workerPoolOptions = createDiffWorkerPoolOptions(workerModuleURL);
  const highlighterOptions = workerHighlighterOptions(state.options, appearance);
  const renderedCodeViewOptions = codeViewOptions(state.options, appearance);

  usePageDataAttributes(state);
  usePendingReplacement(payload, label, dispatch);
  useRenderDiff(config, label, dispatch, latestState);
  useKeyboardShortcuts(payload.shortcuts ?? {}, viewerContainerRef, dispatch);
  useOptionsDismiss(state.optionsOpen, dispatch);

  const selectedTreePath = state.treeSource?.treePathByItemId.get(state.activeItemId) ?? state.activeTreePath;
  const scrollToItem = (itemId: string) => {
    const target = scrollTargetForItem(itemId, state.items);
    if (!target) {
      return;
    }
    codeViewRef.current?.scrollTo({ type: "item", id: target, align: "start", behavior: "smooth-auto" });
    dispatch({
      type: "set-active-item",
      itemId: target,
      treePath: state.treeSource?.treePathByItemId.get(target),
    });
  };
  const setStatus = (status: DiffViewerStatus) => {
    applyDiffViewerStatusToDocument(status);
    dispatch({ type: "set-status", status });
  };

  return (
    <div id="app">
      <Toolbar
        config={config}
        label={label}
        onCopyGitApply={async () => {
          try {
            const message = await copyGitApplyCommand(payload.patchURL, label, copyFallbackRef.current);
            dispatch({ type: "set-copy-feedback", message });
          } catch {
            dispatch({ type: "set-copy-feedback", message: label("copyFailedGitApplyCommand") });
          }
        }}
        onJump={scrollToItem}
        onNavigate={(url) => {
          setStatus(createDiffViewerStatus(label("loadingDiff"), { pending: true }));
          window.location.href = resolveDiffNavigationURL(url);
        }}
        onReload={() => window.location.reload()}
        dispatch={dispatch}
        state={state}
      />
      <section id="content" style={{ "--cmux-diff-files-width": `${state.filesWidth}px` } as React.CSSProperties}>
        <FilesSidebar
          label={label}
          onSelectItem={scrollToItem}
          selectedPath={selectedTreePath}
          dispatch={dispatch}
          state={state}
        />
        <main id="viewer" aria-label={label("diffViewer")}>
          {state.items.length > 0 ? (
            <WorkerPoolContextProvider
              poolOptions={workerPoolOptions}
              highlighterOptions={highlighterOptions}
            >
              <WorkerRenderOptionsSync codeViewRef={codeViewRef} highlighterOptions={highlighterOptions} />
              <CodeView
                ref={codeViewRef}
                className="code-view-root"
                containerRef={viewerContainerRef}
                items={state.items}
                options={renderedCodeViewOptions}
              />
            </WorkerPoolContextProvider>
          ) : null}
        </main>
        <LoadingLayer label={label} status={state.status} />
      </section>
      <textarea
        ref={copyFallbackRef}
        aria-hidden="true"
        readOnly
        tabIndex={-1}
        className="copy-fallback-textarea"
      />
    </div>
  );
}

function resolveDiffViewerAssetURL(rawURL: string | undefined): URL {
  return new URL(rawURL || defaultWorkerModuleURL, window.location.href);
}

function WorkerRenderOptionsSync({
  codeViewRef,
  highlighterOptions,
}: {
  codeViewRef: React.MutableRefObject<CodeViewHandle<any> | null>;
  highlighterOptions: ReturnType<typeof workerHighlighterOptions>;
}) {
  useWorkerRenderOptionsSync(highlighterOptions, codeViewRef);
  return null;
}

function Toolbar({
  config,
  dispatch,
  label,
  onCopyGitApply,
  onJump,
  onNavigate,
  onReload,
  state,
}: {
  config: DiffViewerConfig;
  dispatch: React.Dispatch<AppAction>;
  label: DiffViewerLabelResolver;
  onCopyGitApply: () => void;
  onJump: (itemId: string) => void;
  onNavigate: (url: string) => void;
  onReload: () => void;
  state: AppState;
}) {
  const payload = config.payload ?? {};
  return (
    <header id="toolbar">
      <SourceControls label={label} onNavigate={onNavigate} payload={payload} />
      <div className="toolbar-middle flex min-w-0 flex-1 items-center justify-center gap-1.5">
        <JumpSelect items={state.items} label={label} onJump={onJump} selectedItemId={state.activeItemId} />
      </div>
      <div className="toolbar-actions flex shrink-0 items-center gap-1.5">
        {typeof payload.externalURL === "string" && payload.externalURL.length > 0 ? (
          <a
            id="external-link"
            className="toolbar-icon"
            href={payload.externalURL}
            target="_blank"
            rel="noreferrer"
            title={label("openSourceURL")}
            aria-label={label("openSourceURL")}
          >
            <Icon name="external" />
          </a>
        ) : null}
        <button
          id="files-toggle"
          className="toolbar-icon"
          type="button"
          title={state.filesVisible ? label("hideFiles") : label("showFiles")}
          aria-label={state.filesVisible ? label("hideFiles") : label("showFiles")}
          aria-pressed={state.filesVisible}
          onClick={() => dispatch({ type: "set-files-visible", visible: !state.filesVisible })}
        >
          <Icon name="files" />
        </button>
        <button
          id="layout-toggle"
          className="toolbar-icon"
          type="button"
          title={state.options.layout === "split" ? label("switchToUnifiedDiff") : label("switchToSplitDiff")}
          aria-label={state.options.layout === "split" ? label("switchToUnifiedDiff") : label("switchToSplitDiff")}
          onClick={() => dispatch({ type: "set-option", key: "layout", value: state.options.layout === "split" ? "unified" : "split" })}
        >
          <Icon name={state.options.layout} />
        </button>
        <button
          id="options-button"
          className="toolbar-icon"
          type="button"
          title={label("options")}
          aria-label={label("options")}
          aria-expanded={state.optionsOpen}
          aria-controls="options-menu"
          onClick={() => dispatch({ type: "set-options-open", open: !state.optionsOpen })}
        >
          <Icon name="dots" />
        </button>
        <span id="copy-feedback" className="visually-hidden" aria-live="polite">
          {state.copyFeedback}
        </span>
      </div>
      {state.optionsOpen ? (
        <OptionsMenu
          dispatch={dispatch}
          label={label}
          onCopyGitApply={onCopyGitApply}
          onReload={onReload}
          state={state}
        />
      ) : null}
    </header>
  );
}

function SourceControls({
  label,
  onNavigate,
  payload,
}: {
  label: DiffViewerLabelResolver;
  onNavigate: (url: string) => void;
  payload: any;
}) {
  return (
    <div className="toolbar-left flex min-w-0 items-center gap-1.5">
      <NavigationSelect
        ariaLabel={label("diffTarget")}
        fallbackValue=""
        id="source-select"
        options={payload.sourceOptions}
        onNavigate={onNavigate}
      />
      <NavigationSelect
        ariaLabel={label("repoPath")}
        fallbackValue={payload.repoRoot ?? ""}
        id="repo-select"
        options={payload.repoOptions}
        onNavigate={onNavigate}
      />
      <NavigationSelect
        ariaLabel={label("branchBase")}
        fallbackValue={payload.branchBaseRef ?? ""}
        id="base-select"
        options={payload.baseOptions}
        onNavigate={onNavigate}
      />
      <span id="source-detail">{selectedSourceDetail(payload)}</span>
    </div>
  );
}

function NavigationSelect({
  ariaLabel,
  fallbackValue,
  id,
  onNavigate,
  options,
}: {
  ariaLabel: string;
  fallbackValue: string;
  id: string;
  onNavigate: (url: string) => void;
  options: any[] | undefined;
}) {
  if (!Array.isArray(options) || options.length < 2) {
    return null;
  }
  const selected = options.find((option) => option.selected) ?? options.find((option) => !option.disabled);
  return (
    <select
      id={id}
      aria-label={ariaLabel}
      defaultValue={selected?.value ?? fallbackValue}
      title={ariaLabel}
      onChange={(event) => {
        const next = options.find((option) => option.value === event.currentTarget.value);
        if (!next?.url) {
          event.currentTarget.value = selected?.value ?? fallbackValue;
          return;
        }
        onNavigate(next.url);
      }}
    >
      {options.map((option) => (
        <option
          key={option.value}
          value={option.value}
          disabled={option.disabled || !option.url}
          title={option.message}
        >
          {option.label}
        </option>
      ))}
    </select>
  );
}

function selectedSourceDetail(payload: any): string {
  const selectedSource = Array.isArray(payload.sourceOptions)
    ? payload.sourceOptions.find((option: any) => option.selected) ?? payload.sourceOptions.find((option: any) => !option.disabled)
    : null;
  return selectedSource?.sourceLabel ?? diffSourceDetail(payload);
}

function JumpSelect({
  items,
  label,
  onJump,
  selectedItemId,
}: {
  items: DiffItem[];
  label: DiffViewerLabelResolver;
  onJump: (itemId: string) => void;
  selectedItemId: string;
}) {
  if (items.length === 0) {
    return null;
  }
  return (
    <select
      id="jump-select"
      aria-label={label("jumpToFile")}
      value={selectedItemId}
      onChange={(event) => onJump(event.currentTarget.value)}
    >
      <option value="">{label("jumpToFile")}</option>
      {items.map((item) => (
        <option key={item.id} value={item.id}>
          {fileName(item.fileDiff, label("untitled"))}
        </option>
      ))}
    </select>
  );
}

function OptionsMenu({
  dispatch,
  label,
  onCopyGitApply,
  onReload,
  state,
}: {
  dispatch: React.Dispatch<AppAction>;
  label: DiffViewerLabelResolver;
  onCopyGitApply: () => void;
  onReload: () => void;
  state: AppState;
}) {
  const toggle = (key: keyof DiffViewerOptions) => dispatch({ type: "set-option", key, value: !state.options[key] });
  return (
    <div id="options-menu" aria-label={label("options")}>
      <MenuButton icon="refresh" label={label("refresh")} onClick={onReload} />
      <MenuButton checked={state.options.wordWrap} icon="wrap" label={state.options.wordWrap ? label("disableWordWrap") : label("enableWordWrap")} onClick={() => toggle("wordWrap")} />
      <MenuButton checked={state.options.collapsed} icon="collapse" label={state.options.collapsed ? label("expandAllDiffs") : label("collapseAllDiffs")} onClick={() => toggle("collapsed")} />
      <div className="menu-separator" />
      <MenuButton checked={state.filesVisible} icon="files" label={state.filesVisible ? label("hideFiles") : label("showFiles")} onClick={() => dispatch({ type: "set-files-visible", visible: !state.filesVisible })} />
      <MenuButton checked={state.options.expandUnchanged} icon="document" label={state.options.expandUnchanged ? label("collapseUnchangedContext") : label("expandUnchangedContext")} onClick={() => toggle("expandUnchanged")} />
      <MenuButton checked={state.options.showBackgrounds} icon="background" label={state.options.showBackgrounds ? label("hideBackgrounds") : label("showBackgrounds")} onClick={() => toggle("showBackgrounds")} />
      <MenuButton checked={state.options.lineNumbers} icon="numbers" label={state.options.lineNumbers ? label("hideLineNumbers") : label("showLineNumbers")} onClick={() => toggle("lineNumbers")} />
      <MenuButton checked={state.options.wordDiffs} icon="word" label={state.options.wordDiffs ? label("disableWordDiffs") : label("enableWordDiffs")} onClick={() => toggle("wordDiffs")} />
      <div className="menu-item menu-segment">
        <Icon name="bars" />
        <span className="menu-label">{label("indicatorStyle")}</span>
        <span className="menu-segment-controls">
          {[
            { value: "bars", icon: "bars", label: label("bars") },
            { value: "classic", icon: "classic", label: label("classic") },
            { value: "none", icon: "eye", label: label("none") },
          ].map((option) => (
            <button
              key={option.value}
              type="button"
              className="segment-button"
              title={option.label}
              aria-label={option.label}
              aria-pressed={state.options.diffIndicators === option.value}
              onClick={() => dispatch({ type: "set-option", key: "diffIndicators", value: option.value })}
            >
              <Icon name={option.icon as IconName} />
            </button>
          ))}
        </span>
      </div>
      <div className="menu-separator" />
      <MenuButton icon="clipboard" label={label("copyGitApplyCommand")} onClick={onCopyGitApply} />
    </div>
  );
}

function MenuButton({
  checked,
  icon,
  label,
  onClick,
}: {
  checked?: boolean;
  icon: Parameters<typeof Icon>[0]["name"];
  label: string;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      className="menu-item"
      aria-pressed={checked == null ? undefined : checked}
      onClick={onClick}
    >
      <Icon name={icon} />
      <span className="menu-label">{label}</span>
      <span className="menu-check">{checked ? <Icon name="check" /> : null}</span>
    </button>
  );
}

function FilesSidebar({
  dispatch,
  label,
  onSelectItem,
  selectedPath,
  state,
}: {
  dispatch: React.Dispatch<AppAction>;
  label: DiffViewerLabelResolver;
  onSelectItem: (itemId: string) => void;
  selectedPath: string;
  state: AppState;
}) {
  const dragStart = useRef<{ startWidth: number; startX: number } | null>(null);
  const resizeFiles = (clientX: number) => {
    const start = dragStart.current;
    if (!start) {
      return;
    }
    const viewportWidth = document.documentElement.clientWidth || window.innerWidth;
    const maximumWidth = Math.max(220, Math.min(520, Math.floor(viewportWidth * 0.55)));
    const nextWidth = Math.max(180, Math.min(maximumWidth, Math.round(start.startWidth - (clientX - start.startX))));
    dispatch({ type: "set-files-width", width: nextWidth });
  };
  return (
    <aside id="files-sidebar" aria-label={label("changedFiles")} aria-hidden={!state.filesVisible} inert={!state.filesVisible}>
      <button
        id="files-resize-handle"
        aria-label={label("files")}
        type="button"
        tabIndex={0}
        onPointerDown={(event) => {
          dragStart.current = { startWidth: state.filesWidth, startX: event.clientX };
          event.currentTarget.setPointerCapture(event.pointerId);
        }}
        onPointerMove={(event) => resizeFiles(event.clientX)}
        onPointerUp={(event) => {
          resizeFiles(event.clientX);
          dragStart.current = null;
          event.currentTarget.releasePointerCapture(event.pointerId);
        }}
        onPointerCancel={() => {
          dragStart.current = null;
        }}
        onKeyDown={(event) => {
          if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") {
            return;
          }
          event.preventDefault();
          const delta = event.key === "ArrowLeft" ? 20 : -20;
          dispatch({ type: "set-files-width", width: Math.max(180, Math.min(520, state.filesWidth + delta)) });
        }}
      />
      <div id="files-header">
        <span id="files-title">
          <span>{label("files")}</span>
          <span id="files-count">{state.treeSource?.pathCount ?? 0}</span>
        </span>
        <span id="files-header-actions">
          <button
            id="file-search-toggle"
            type="button"
            title={state.fileSearchOpen ? label("hideFileSearch") : label("showFileSearch")}
            aria-label={state.fileSearchOpen ? label("hideFileSearch") : label("showFileSearch")}
            aria-pressed={state.fileSearchOpen}
            disabled={!state.treeSource}
            onClick={() => dispatch({ type: "set-file-search-open", open: !state.fileSearchOpen })}
          >
            <Icon name="search" />
          </button>
          <button
            id="file-collapse-toggle"
            type="button"
            title={label("hideFiles")}
            aria-label={label("hideFiles")}
            onClick={() => dispatch({ type: "set-files-visible", visible: false })}
          >
            <Icon name="sidebarCollapse" />
          </button>
        </span>
      </div>
      <div id="file-list">
        {state.treeSource ? (
          <PierreFileTree
            fileSearchOpen={state.fileSearchOpen}
            label={label}
            onSelectItem={onSelectItem}
            selectedPath={selectedPath}
            source={state.treeSource}
          />
        ) : state.status.loading || state.status.pending ? (
          <LoadingFileList />
        ) : (
          <div className="visually-hidden">{state.status.message}</div>
        )}
      </div>
      <div id="files-footer" aria-label={label("diffStats")}>
        <div className="stats-row">
          <span>{label("files")}</span>
          <strong id="stats-files">{state.treeSource?.diffStats.fileCount ?? 0}</strong>
        </div>
        <div className="stats-row">
          <span>{label("additions")}</span>
          <strong id="stats-added" className="stat-add">+{state.treeSource?.diffStats.addedLines ?? 0}</strong>
        </div>
        <div className="stats-row">
          <span>{label("deletions")}</span>
          <strong id="stats-deleted" className="stat-del">-{state.treeSource?.diffStats.deletedLines ?? 0}</strong>
        </div>
      </div>
    </aside>
  );
}

function PierreFileTree({
  fileSearchOpen,
  label,
  onSelectItem,
  selectedPath,
  source,
}: {
  fileSearchOpen: boolean;
  label: DiffViewerLabelResolver;
  onSelectItem: (itemId: string) => void;
  selectedPath: string;
  source: FileTreeSource;
}) {
  const latest = useSyncedRef({ label, onSelectItem, source });
  const [initialPreparedInput] = useState(() => preparePresortedFileTreeInput(source.paths));
  const { model } = useFileTree({
    flattenEmptyDirectories: false,
    id: "cmux-diff-file-tree",
    initialExpansion: "open",
    initialSelectedPaths: selectedPath ? [selectedPath] : [],
    initialVisibleRowCount: getInitialFileTreeRowCount(),
    itemHeight: 24,
    overscan: 12,
    preparedInput: initialPreparedInput,
    search: true,
    searchBlurBehavior: "retain",
    stickyFolders: true,
    gitStatus: source.gitStatus as any,
    renderRowDecoration(context: any) {
      if (context.item.kind !== "file") {
        return null;
      }
      const stats = latest.current.source.statsByPath.get(context.item.path);
      if (stats == null || (stats.added === 0 && stats.deleted === 0)) {
        return null;
      }
      return {
        text: `+${stats.added} -${stats.deleted}`,
        title: `${stats.added} ${latest.current.label("additions")}, ${stats.deleted} ${latest.current.label("deletions")}`,
      };
    },
    sort: () => 0,
    unsafeCSS: fileTreeUnsafeCSS(),
    onSelectionChange(paths: readonly string[]) {
      const path = paths[paths.length - 1];
      const itemId = latest.current.source.pathToItemId.get(path);
      if (itemId) {
        latest.current.onSelectItem(itemId);
      }
    },
  });

  usePierreFileTreeSource(model, source);
  usePierreFileTreeSearch(model, fileSearchOpen);
  usePierreFileTreeSelection(model, selectedPath);

  return <FileTree model={model} style={{ height: "100%" }} />;
}

function LoadingFileList() {
  return (
    <div className="diff-loading-placeholder" aria-hidden="true">
      {fileSkeletonWidths.map((width, index) => (
        <div key={`${width}-${index}`} className="grid h-6 grid-cols-[16px_minmax(0,1fr)_44px] items-center gap-2 rounded-[5px] px-[7px]">
          <span className="size-4 rounded-[5px] border border-[color-mix(in_lab,var(--cmux-diff-fg)_18%,transparent)]" />
          <span className="h-[11px] rounded bg-[var(--cmux-diff-muted-bg)]" style={{ width }} />
          <span className="h-[11px] justify-self-end rounded bg-[var(--cmux-diff-muted-bg)] opacity-70" style={{ width: index % 2 === 0 ? "34px" : "24px" }} />
        </div>
      ))}
    </div>
  );
}

function LoadingDiffSkeleton() {
  return (
    <div className="diff-loading-placeholder mx-3.5 mt-3.5 border-t border-[var(--cmux-diff-border)] pt-3" aria-hidden="true">
      <div className="mb-3 grid h-9 grid-cols-[72px_minmax(0,1fr)_96px] items-center gap-3 rounded-md bg-[color-mix(in_lab,var(--cmux-diff-fg)_5%,transparent)] px-3">
        <span className="h-3 rounded bg-[var(--cmux-diff-muted-bg)]" />
        <span className="h-3 w-2/5 rounded bg-[var(--cmux-diff-muted-bg)]" />
        <span className="h-3 rounded bg-[var(--cmux-diff-muted-bg)] opacity-70" />
      </div>
      <div className="space-y-[13px] px-3 py-1">
        {diffSkeletonWidths.map((width, index) => (
          <div key={`${width}-${index}`} className="grid grid-cols-[42px_minmax(0,1fr)] items-center gap-4">
            <span className="h-px bg-[color-mix(in_lab,var(--cmux-diff-fg)_10%,transparent)]" />
            <span className="h-3 rounded bg-[var(--cmux-diff-muted-bg)]" style={{ width }} />
          </div>
        ))}
      </div>
    </div>
  );
}

function LoadingLayer({ label, status }: { label: DiffViewerLabelResolver; status: DiffViewerStatus }) {
  if (!status.loading && !status.pending && !status.statusOnly && !status.error) {
    return null;
  }
  return (
    <div id="loading-layer" aria-live="polite">
      <div id="status" data-error={status.error ? "true" : "false"} data-pending={status.pending ? "true" : "false"}>
        <span id="status-icon" aria-hidden="true" />
        <span id="status-text">{status.message || label("loadingDiff")}</span>
      </div>
      {status.loading || status.pending ? <LoadingDiffSkeleton /> : null}
    </div>
  );
}

function useSyncedRef<T>(value: T): React.MutableRefObject<T> {
  const ref = useRef(value);
  useEffect(() => {
    ref.current = value;
  }, [value]);
  return ref;
}

function useWorkerRenderOptionsSync(
  highlighterOptions: ReturnType<typeof workerHighlighterOptions>,
  codeViewRef: React.MutableRefObject<CodeViewHandle<any> | null>,
): void {
  const workerPool = useWorkerPool();
  const syncedOptions = useRef<ReturnType<typeof workerHighlighterOptions> | null>(null);
  useEffect(() => {
    if (!workerPool || sameWorkerHighlighterOptions(syncedOptions.current, highlighterOptions)) {
      return;
    }
    let active = true;
    syncedOptions.current = highlighterOptions;
    workerPool.setRenderOptions(highlighterOptions)
      .then(() => {
        if (active) {
          codeViewRef.current?.getInstance()?.render(true);
        }
      })
      .catch((error: unknown) => console.warn("cmux diff worker render options update failed", error));
    return () => {
      active = false;
    };
  }, [codeViewRef, highlighterOptions, workerPool]);
}

function sameWorkerHighlighterOptions(
  previous: ReturnType<typeof workerHighlighterOptions> | null,
  next: ReturnType<typeof workerHighlighterOptions>,
): boolean {
  return previous?.lineDiffType === next.lineDiffType &&
    previous?.maxLineDiffLength === next.maxLineDiffLength &&
    previous?.preferredHighlighter === next.preferredHighlighter &&
    sameThemeOption(previous?.theme, next.theme) &&
    previous?.tokenizeMaxLineLength === next.tokenizeMaxLineLength &&
    previous?.useTokenTransformer === next.useTokenTransformer;
}

function sameThemeOption(
  previous: ReturnType<typeof workerHighlighterOptions>["theme"] | undefined,
  next: ReturnType<typeof workerHighlighterOptions>["theme"],
): boolean {
  if (previous === next) {
    return true;
  }
  if (typeof previous !== "object" || previous == null || typeof next !== "object" || next == null) {
    return false;
  }
  return (previous as { dark?: string }).dark === (next as { dark?: string }).dark &&
    (previous as { light?: string }).light === (next as { light?: string }).light;
}

function usePierreFileTreeSource(
  model: ReturnType<typeof useFileTree>["model"],
  source: FileTreeSource,
): void {
  const previousSource = useRef<FileTreeSource | null>(null);
  useEffect(() => {
    const previous = previousSource.current;
    previousSource.current = source;
    const plan = planPierreFileTreeRefresh(previous, source, source.paths);
    let useFullGitStatus = plan.kind === "append" ? plan.requiresFullGitStatus : false;
    if (plan.kind === "append") {
      if (plan.addedPaths.length > 0) {
        try {
          model.batch(plan.addedPaths.map((path) => ({ type: "add", path })));
          useFullGitStatus = !plan.sourceFollowsPrevious;
        } catch {
          const preparedInput = preparePresortedFileTreeInput(source.paths);
          model.resetPaths(source.paths, { preparedInput });
          useFullGitStatus = true;
        }
      }
    } else {
      const preparedInput = preparePresortedFileTreeInput(source.paths);
      model.resetPaths(source.paths, { preparedInput });
      useFullGitStatus = true;
    }
    applyPierreFileTreeGitStatus(model as any, source, useFullGitStatus);
  }, [model, source]);
}

function usePierreFileTreeSearch(model: ReturnType<typeof useFileTree>["model"], fileSearchOpen: boolean): void {
  useEffect(() => {
    if (fileSearchOpen) {
      model.openSearch("");
    } else {
      model.closeSearch();
    }
  }, [fileSearchOpen, model]);
}

function usePierreFileTreeSelection(model: ReturnType<typeof useFileTree>["model"], selectedPath: string): void {
  useEffect(() => {
    selectPierreFileTreePath(model, selectedPath);
  }, [model, selectedPath]);
}

function useRenderDiff(
  config: DiffViewerConfig,
  label: DiffViewerLabelResolver,
  dispatch: React.Dispatch<AppAction>,
  latestState: React.MutableRefObject<AppState>,
) {
  const started = useRef(false);
  useEffect(() => {
    if (started.current || isStatusOnlyPayload(config.payload)) {
      return;
    }
    started.current = true;
    const payload = config.payload ?? {};
    const appearance = resolveDiffViewerAppearance(payload.appearance);
    if (appearance.themes.light.name) {
      registerCustomTheme(appearance.themes.light.name, () => Promise.resolve(shikiThemeFromGhostty(appearance.themes.light, appearance)));
    }
    if (appearance.themes.dark.name) {
      registerCustomTheme(appearance.themes.dark.name, () => Promise.resolve(shikiThemeFromGhostty(appearance.themes.dark, appearance)));
    }
    const streamedItems: DiffItem[] = [];
    dispatch({ type: "set-status", status: createDiffViewerStatus(label("parsingDiff"), { loading: true }) });
    streamPatch({
      getCollapsed: () => latestState.current.options.collapsed,
      initialFileTreeRowCount: getInitialFileTreeRowCount(),
      label,
      onBatch: (items) => {
        streamedItems.push(...items);
        dispatch({ type: "append-items", items });
      },
      onComplete: (metrics) => {
        dispatch({ type: "set-metrics", metrics });
        const items = streamedItems;
        if (items.length === 0) {
          dispatch({ type: "set-status", status: createDiffViewerStatus(label("noFileDiffs"), { error: true, loading: false, statusOnly: true }) });
          return;
        }
        const themes = Array.from(new Set([appearance.theme?.light, appearance.theme?.dark].filter(Boolean)));
        const langs = Array.from(new Set(items.flatMap((item) => {
          const diff = item.fileDiff ?? {};
          const lang = diff.lang ?? getFiletypeFromFileName(fileName(diff, "")) ?? "text";
          return lang ? [lang] : [];
        })));
        preloadHighlighter({ themes, langs: langs.length > 0 ? langs : ["text"] })
          .catch((error) => console.warn("cmux diff highlighter preload failed", error));
      },
      onMetrics: (metrics) => dispatch({ type: "set-metrics", metrics }),
      onRename: (rename) => dispatch({ type: "rename-item", oldId: rename.oldId, newId: rename.newId }),
      onTreeSource: (source) => dispatch({ type: "set-tree-source", source }),
      parsePatchFiles,
      patchURL: payload.patchURL,
      processFile,
    }).catch((error) => {
      console.error("cmux diff viewer render failed", error);
      dispatch({ type: "set-status", status: createDiffViewerStatus(label("renderFailed"), { error: true, loading: false, statusOnly: true }) });
    });
  }, [config, dispatch, label, latestState]);
}

function isStatusOnlyPayload(payload: any): boolean {
  return payload?.pendingReplacement === true ||
    (typeof payload?.statusMessage === "string" && payload.statusMessage.length > 0);
}

function usePendingReplacement(payload: any, label: DiffViewerLabelResolver, dispatch: React.Dispatch<AppAction>) {
  const started = useRef(false);
  useEffect(() => {
    if (started.current) {
      return;
    }
    started.current = true;
    if (payload.pendingReplacement === true) {
      dispatch({
        type: "set-status",
        status: createDiffViewerStatus(payload.statusMessage ?? label("loadingDiff"), { loading: true, pending: true }),
      });
      fetch("/__cmux_diff_viewer_wait" + location.pathname, { cache: "no-store" })
        .then(async (response) => {
          if (!response.ok) {
            throw new Error("replacement failed");
          }
          const text = await response.text();
          if (!text.includes("data-cmux-diff-pending=\"true\"")) {
            window.location.reload();
          }
        })
        .catch((error) => {
          document.documentElement.dataset.cmuxDiffWait = "failed";
          dispatch({ type: "set-status", status: createDiffViewerStatus(label("renderFailed"), { error: true, loading: false, statusOnly: true }) });
          console.warn("cmux diff viewer deferred load failed", error);
        });
      return;
    }
    if (typeof payload.statusMessage === "string" && payload.statusMessage.length > 0) {
      dispatch({
        type: "set-status",
        status: createDiffViewerStatus(payload.statusMessage, {
          error: payload.statusIsError === true,
          loading: false,
          statusOnly: true,
        }),
      });
    }
  }, [dispatch, label, payload]);
}

function usePageDataAttributes(state: AppState) {
  useEffect(() => {
    document.body.dataset.filesHidden = state.filesVisible ? "false" : "true";
    document.body.dataset.loading = state.status.loading ? "true" : "false";
    document.documentElement.dataset.layout = state.options.layout;
    document.documentElement.dataset.wordWrap = String(state.options.wordWrap);
    document.documentElement.dataset.diffIndicators = state.options.diffIndicators;
    if (state.metrics) {
      document.body.dataset.streamFileCount = String(state.metrics.fileCount ?? state.items.length);
      document.body.dataset.streamRenderableFileCount = String(state.metrics.renderableFileCount ?? state.items.length);
      document.body.dataset.streamFlushCount = String(state.metrics.flushCount ?? 0);
      document.body.dataset.streamMaxBatchSize = String(state.metrics.maxBatchSize ?? 0);
      document.body.dataset.streamTreeRefreshCount = String(state.metrics.treeRefreshCount ?? 0);
      if (Number.isFinite(state.metrics.completedAt) && state.metrics.completedAt > 0) {
        document.body.dataset.streamElapsedMs = String(Math.round(state.metrics.completedAt - state.metrics.startedAt));
      }
    }
    applyDiffViewerStatusToDocument(state.status);
  }, [state]);
}

function useKeyboardShortcuts(
  shortcuts: any,
  viewerRef: React.MutableRefObject<HTMLDivElement | null>,
  dispatch: React.Dispatch<AppAction>,
) {
  useEffect(() => {
    const scrollDownShortcut = normalizeShortcut(shortcuts.diffViewerScrollDown);
    const scrollUpShortcut = normalizeShortcut(shortcuts.diffViewerScrollUp);
    const scrollBottomShortcut = normalizeShortcut(shortcuts.diffViewerScrollToBottom);
    const scrollTopShortcut = normalizeShortcut(shortcuts.diffViewerScrollToTop);
    const fileSearchShortcut = normalizeShortcut(shortcuts.diffViewerOpenFileSearch);
    let pendingChord: PendingChord | null = null;
    let chordTimeout = 0;
    const clearPendingChord = () => {
      pendingChord = null;
      if (chordTimeout !== 0) {
        window.clearTimeout(chordTimeout);
        chordTimeout = 0;
      }
    };
    const listener = (event: KeyboardEvent) => {
      if (event.defaultPrevented || isTypingShortcutTarget(event.target)) {
        return;
      }
      if (pendingChord && !shortcutStrokeMatchesEvent(pendingChord.shortcut.second, event)) {
        clearPendingChord();
      }
      if (pendingChord && shortcutStrokeMatchesEvent(pendingChord.shortcut.second, event)) {
        event.preventDefault();
        pendingChord.action();
        clearPendingChord();
        return;
      }
      if (shortcutMatchesEvent(scrollDownShortcut, event)) {
        event.preventDefault();
        scrollViewerBy(viewerRef.current, 1);
        return;
      }
      if (shortcutMatchesEvent(scrollUpShortcut, event)) {
        event.preventDefault();
        scrollViewerBy(viewerRef.current, -1);
        return;
      }
      if (shortcutMatchesEvent(scrollBottomShortcut, event)) {
        event.preventDefault();
        viewerRef.current?.scrollTo({ top: viewerRef.current.scrollHeight, behavior: "auto" });
        return;
      }
      if (shortcutMatchesEvent(fileSearchShortcut, event)) {
        event.preventDefault();
        dispatch({ type: "set-file-search-open", open: true });
        return;
      }
      if (scrollTopShortcut && shortcutStartsChord(scrollTopShortcut, event)) {
        event.preventDefault();
        pendingChord = {
          shortcut: scrollTopShortcut,
          action: () => viewerRef.current?.scrollTo({ top: 0, behavior: "auto" }),
        };
        chordTimeout = window.setTimeout(clearPendingChord, 700);
      }
    };
    document.addEventListener("keydown", listener);
    return () => {
      clearPendingChord();
      document.removeEventListener("keydown", listener);
    };
  }, [dispatch, shortcuts, viewerRef]);
}

function useOptionsDismiss(optionsOpen: boolean, dispatch: React.Dispatch<AppAction>) {
  useEffect(() => {
    if (!optionsOpen) {
      return;
    }
    const closeOnOutsideClick = (event: MouseEvent) => {
      if (event.target instanceof Element && event.target.closest("#toolbar")) {
        return;
      }
      dispatch({ type: "set-options-open", open: false });
    };
    const closeOnEscape = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        dispatch({ type: "set-options-open", open: false });
      }
    };
    document.addEventListener("click", closeOnOutsideClick);
    document.addEventListener("keydown", closeOnEscape);
    return () => {
      document.removeEventListener("click", closeOnOutsideClick);
      document.removeEventListener("keydown", closeOnEscape);
    };
  }, [dispatch, optionsOpen]);
}

type ShortcutStroke = {
  command: boolean;
  control: boolean;
  key: string;
  option: boolean;
  shift: boolean;
};

type ShortcutBinding = {
  first: ShortcutStroke;
  second: ShortcutStroke | null;
};

type PendingChord = {
  action: () => void;
  shortcut: ShortcutBinding;
};

function normalizeShortcut(rawShortcut: any): ShortcutBinding | null {
  if (!rawShortcut || rawShortcut.unbound === true || !rawShortcut.first) {
    return null;
  }
  return {
    first: normalizeShortcutStroke(rawShortcut.first),
    second: rawShortcut.second ? normalizeShortcutStroke(rawShortcut.second) : null,
  };
}

function normalizeShortcutStroke(rawStroke: any): ShortcutStroke {
  return {
    key: String(rawStroke?.key ?? "").toLowerCase(),
    command: rawStroke?.command === true,
    shift: rawStroke?.shift === true,
    option: rawStroke?.option === true,
    control: rawStroke?.control === true,
  };
}

function shortcutMatchesEvent(shortcut: ShortcutBinding | null, event: KeyboardEvent): boolean {
  return Boolean(shortcut && !shortcut.second && shortcutStrokeMatchesEvent(shortcut.first, event));
}

function shortcutStartsChord(shortcut: ShortcutBinding, event: KeyboardEvent): boolean {
  return Boolean(shortcut.second && shortcutStrokeMatchesEvent(shortcut.first, event));
}

function shortcutStrokeMatchesEvent(stroke: ShortcutStroke | null, event: KeyboardEvent): boolean {
  if (!stroke || event.metaKey !== stroke.command || event.ctrlKey !== stroke.control || event.altKey !== stroke.option) {
    return false;
  }
  if (event.shiftKey !== stroke.shift) {
    return false;
  }
  return normalizedShortcutEventKey(event) === stroke.key;
}

function normalizedShortcutEventKey(event: KeyboardEvent): string {
  if (event.code === "Space") {
    return "space";
  }
  if (typeof event.key !== "string" || event.key.length === 0) {
    return "";
  }
  return event.key.length === 1 ? event.key.toLowerCase() : event.key.toLowerCase();
}

function isTypingShortcutTarget(target: EventTarget | null): boolean {
  const element = target instanceof Element ? target : null;
  return Boolean(element?.closest("input, textarea, select, [contenteditable='true']"));
}

function scrollViewerBy(viewer: HTMLDivElement | null, direction: number): void {
  if (!viewer) {
    return;
  }
  const amount = Math.max(80, Math.floor(viewer.clientHeight * 0.38));
  viewer.scrollBy({ top: direction * amount, behavior: "auto" });
}

function scrollTargetForItem(itemId: string, items: DiffItem[]): string {
  if (items.some((item) => item.id === itemId)) {
    return itemId;
  }
  return items[0]?.id ?? "";
}

function getInitialFileTreeRowCount(): number {
  const viewportHeight = window.visualViewport?.height ?? window.innerHeight;
  if (!Number.isFinite(viewportHeight) || viewportHeight <= 0) {
    return 25;
  }
  return Math.min(96, Math.max(25, Math.ceil(viewportHeight / 24)));
}
