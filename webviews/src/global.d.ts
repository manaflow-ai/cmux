export {};

declare global {
  interface Window {
    __cmuxDiffViewer?: {
      codeView?: unknown;
      codeViewItems?: unknown[];
      items?: unknown[];
      state?: unknown;
      streamMetrics?: unknown;
      workerPool?: unknown;
    };
    __cmuxMobileDiff?: {
      selectFile(itemId: string): void;
    };
  }
}
