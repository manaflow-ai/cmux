// Owns the viewer's document-level wiring: page data attributes, native viewer navigation, and
// the dismiss rules of the options menu and file search.
import { useEffect, useLayoutEffect, useRef } from "react";
import { computedTranslateX, createFilesPanelMotion, type FilesPanelMotion } from "../files-panel-motion";
import { applyDiffViewerStatusToDocument } from "../status";
import { type DiffFindController } from "../find/useDiffFind";
import { type AppAction, type AppState } from "./state";

function setDataset(dataset: DOMStringMap, key: string, value: string): void {
  if (dataset[key] !== value) dataset[key] = value;
}

export function usePageDataAttributes(state: AppState) {
  // The files panel shows and hides through its motion (files-panel-motion.ts),
  // which flips `data-files-hidden` in this commit's frame and slides the
  // panel on the compositor afterwards.
  const filesPanelMotion = useRef<FilesPanelMotion | null>(null);
  useLayoutEffect(() => {
    filesPanelMotion.current ??= createFilesPanelMotion({
      panel: () => document.getElementById("files-sidebar"),
      curtain: () => document.getElementById("files-motion-curtain"),
      timelineTime: () => {
        const time = document.timeline?.currentTime;
        return typeof time === "number" ? time : null;
      },
      body: document.body,
      currentOffset: (panel) => computedTranslateX(panel as HTMLElement),
      requestFrame: (callback) => requestAnimationFrame(() => callback()),
      reducedMotion: () => window.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false,
    });
    filesPanelMotion.current.set(state.filesVisible);
  }, [state.filesVisible]);
  useEffect(() => {
    // Written only when a value changes: an attribute write on <html> or <body> invalidates style
    // for the whole document, and this runs after every state change (an input's frame included).
    const body = document.body.dataset;
    const root = document.documentElement.dataset;
    setDataset(body, "loading", state.status.loading ? "true" : "false");
    setDataset(root, "layout", state.options.layout);
    setDataset(root, "wordWrap", String(state.options.wordWrap));
    setDataset(root, "diffIndicators", state.options.diffIndicators);
    setDataset(body, "generatedPathCount", String(state.generatedPaths.length));
    if (state.metrics) {
      setDataset(body, "streamFileCount", String(state.metrics.fileCount ?? state.items.length));
      setDataset(body, "streamRenderableFileCount", String(state.metrics.renderableFileCount ?? state.items.length));
      setDataset(body, "streamFlushCount", String(state.metrics.flushCount ?? 0));
      setDataset(body, "streamMaxBatchSize", String(state.metrics.maxBatchSize ?? 0));
      setDataset(body, "streamTreeRefreshCount", String(state.metrics.treeRefreshCount ?? 0));
      if (Number.isFinite(state.metrics.completedAt) && state.metrics.completedAt > 0) {
        setDataset(body, "streamElapsedMs", String(Math.round(state.metrics.completedAt - state.metrics.startedAt)));
      }
    }
    applyDiffViewerStatusToDocument(state.status);
  }, [state]);
}

export function useNativeViewerNavigation(
  viewerRef: React.MutableRefObject<HTMLDivElement | null>,
  dispatch: React.Dispatch<AppAction>,
  onJumpAdjacentFile: (direction: -1 | 1) => void,
  onJumpAdjacentHunk: (direction: -1 | 1) => void,
  onToggleViewed: () => void,
  onSetCurrentCollapsed: (collapsed: boolean) => void,
  findBridgeRef: React.MutableRefObject<{ open: boolean; controller: DiffFindController }>,
) {
  useEffect(() => {
    window.__cmuxPerformDiffViewerNavigationAction = (action: string) => {
      const viewer = viewerRef.current;
      if (viewer && CmuxViewerNavigation.performAction(action, viewer)) {
        return true;
      }
      const findBridge = findBridgeRef.current;
      switch (action) {
        case "diffViewerOpenFileSearch":
          dispatch({ type: "request-file-search" });
          return true;
        case "diffViewerNextFile":
          if (viewer) CmuxViewerNavigation.resetSmoothTarget(viewer);
          onJumpAdjacentFile(1);
          return true;
        case "diffViewerPreviousFile":
          if (viewer) CmuxViewerNavigation.resetSmoothTarget(viewer);
          onJumpAdjacentFile(-1);
          return true;
        case "diffViewerNextHunk":
          if (viewer) CmuxViewerNavigation.resetSmoothTarget(viewer);
          onJumpAdjacentHunk(1);
          return true;
        case "diffViewerPreviousHunk":
          if (viewer) CmuxViewerNavigation.resetSmoothTarget(viewer);
          onJumpAdjacentHunk(-1);
          return true;
        case "diffViewerToggleViewed":
          onToggleViewed();
          return true;
        case "diffViewerCollapseFile":
          onSetCurrentCollapsed(true);
          return true;
        case "diffViewerExpandFile":
          onSetCurrentCollapsed(false);
          return true;
        case "diffViewerOpenFind":
          dispatch({ type: "request-find" });
          return true;
        case "diffViewerFindNext":
          if (!findBridge.open) return false;
          findBridge.controller.goToNext();
          return true;
        case "diffViewerFindPrevious":
          if (!findBridge.open) return false;
          findBridge.controller.goToPrevious();
          return true;
        case "diffViewerCloseFind":
          if (!findBridge.open) return false;
          findBridge.controller.closeFind();
          return true;
      }
      return false;
    };
    document.documentElement.dataset.cmuxViewerNavigationReady = "true";
    document.dispatchEvent(new window.Event("cmux-diff-viewer-navigation-readiness-change"));
    const disposeManualInputReset = CmuxViewerNavigation.installManualInputReset({
      target: document,
      getScroller: () => viewerRef.current!,
    });
    return () => {
      delete window.__cmuxPerformDiffViewerNavigationAction;
      delete document.documentElement.dataset.cmuxViewerNavigationReady;
      document.dispatchEvent(new window.Event("cmux-diff-viewer-navigation-readiness-change"));
      disposeManualInputReset();
    };
  }, [
    dispatch,
    findBridgeRef,
    onJumpAdjacentFile,
    onJumpAdjacentHunk,
    onSetCurrentCollapsed,
    onToggleViewed,
    viewerRef,
  ]);
}

export function useOptionsDismiss(optionsOpen: boolean, dispatch: React.Dispatch<AppAction>) {
  useEffect(() => {
    if (!optionsOpen) {
      return;
    }
    const closeOnOutsideClick = (event: MouseEvent) => {
      if (event.target instanceof Element && event.target.closest("#diff-pill")) {
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

export function closeFileSearch(dispatch: React.Dispatch<AppAction>, targetDocument: Document = document) {
  dispatch({ type: "set-file-search-open", open: false });
  const trigger = targetDocument.getElementById("jump-search-button") ?? targetDocument.getElementById("jump-select");
  trigger?.focus();
}

export function shouldDismissFileSearch(key: string, narrowViewport: boolean): boolean {
  return key === "Escape" && narrowViewport;
}

export function useFileSearchDismiss(fileSearchOpen: boolean, dispatch: React.Dispatch<AppAction>) {
  useEffect(() => {
    if (!fileSearchOpen) {
      return;
    }
    const closeOnEscape = (event: KeyboardEvent) => {
      if (shouldDismissFileSearch(event.key, window.matchMedia("(max-width: 520px)").matches)) {
        event.preventDefault();
        closeFileSearch(dispatch);
      }
    };
    document.addEventListener("keydown", closeOnEscape);
    return () => document.removeEventListener("keydown", closeOnEscape);
  }, [dispatch, fileSearchOpen]);
}
