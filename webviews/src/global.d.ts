export {};

declare global {
  var CmuxViewerNavigation: {
    install(options: {
      target: Document | HTMLElement;
      getScroller: () => HTMLElement;
      shortcuts: Record<string, unknown>;
    }): () => void;
    installManualInputReset(options: {
      target: Document | HTMLElement;
      getScroller: () => HTMLElement;
    }): () => void;
    performAction(action: string, scroller: HTMLElement): boolean;
    resetSmoothTarget(scroller: HTMLElement): void;
  };

  interface Window {
    __cmuxPerformDiffViewerNavigationAction?: (action: string) => boolean;
    __cmuxDiffViewer?: {
      codeView?: unknown;
      codeViewItems?: unknown[];
      items?: unknown[];
      state?: unknown;
      streamMetrics?: unknown;
      workerPool?: unknown;
    };
  }
}
