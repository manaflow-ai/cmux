// Prototype (plans/cmux-next/diff-perf.md): a minimal viewer on the lazy-hunks sidecar
// methods, with the classic viewer's Pierre options, tree options and worker pool, so its
// milestones compare with /diff/ on the same fixture. Not wired into App.tsx.
import { CodeView, type CodeViewHandle, WorkerPoolContextProvider } from "@pierre/diffs/react";
import { registerCustomTheme } from "@pierre/diffs";
import { preparePresortedFileTreeInput } from "@pierre/trees";
import { FileTree, useFileTree } from "@pierre/trees/react";
import { useRef, useState } from "react";
import { resolveDiffViewerAppearance } from "../appearance";
import {
  codeViewOptions,
  shikiThemeFromGhostty,
  workerHighlighterOptions,
  type DiffViewerOptions,
} from "../pierre-options";
import { createDiffWorkerPoolOptions } from "../worker-pool";
import {
  createPatchLoader,
  fileDiffFromHunks,
  placeholderDiff,
  type LazyFile,
  type LazyRpc,
  type LazyStats,
} from "./lazy-model";

const options: DiffViewerOptions = {
  collapsed: false,
  diffIndicators: "bars",
  expandUnchanged: false,
  layout: "split",
  lineNumbers: true,
  showBackgrounds: true,
  wordDiffs: false,
  wordWrap: false,
};

export type LazyMetrics = {
  summaryMs?: number;
  statsMs?: number;
  firstPatchesMs?: number;
  patchCalls: number;
  patchedFiles: number;
  rustMs: number[];
};

export function LazyViewer({
  rpc,
  base,
  files,
  appearancePayload,
  metrics,
}: {
  rpc: LazyRpc;
  base: string;
  files: LazyFile[];
  appearancePayload: any;
  metrics: LazyMetrics;
}) {
  const appearance = resolveDiffViewerAppearance(appearancePayload);
  for (const theme of [appearance.themes.light, appearance.themes.dark]) {
    if (theme.name) registerCustomTheme(theme.name, () => Promise.resolve(shikiThemeFromGhostty(theme, appearance)));
  }
  const codeView = useRef<CodeViewHandle<any> | null>(null);
  const byPath = useRef(new Map(files.map((file) => [file.path, file])));
  const versions = useRef(new Map<string, number>());
  const [initialItems] = useState(() =>
    files.map((file) => ({ id: file.path, type: "diff" as const, fileDiff: placeholderDiff(file), version: 0 })),
  );
  const [loader] = useState(() =>
    createPatchLoader(rpc, base, (patches, deferred, requested) => {
      metrics.patchCalls += 1;
      metrics.firstPatchesMs ??= performance.now();
      const handle = codeView.current;
      if (!handle) return;
      const loaded = new Set<string>();
      for (const patch of patches) {
        const file = byPath.current.get(patch.path);
        if (!file) continue;
        loaded.add(patch.path);
        const version = (versions.current.get(file.path) ?? 0) + 1;
        versions.current.set(file.path, version);
        handle.updateItem({
          id: file.path,
          type: "diff",
          fileDiff: fileDiffFromHunks(file, patch.hunks, `${base}:${file.path}`),
          version,
        });
      }
      metrics.patchedFiles += loaded.size;
      // Deferred (large) and hunkless files keep their header, like the classic "Load diff".
      void deferred;
      void requested;
      document.body.dataset.streamElapsedMs ??= String(Math.round(performance.now()));
    }),
  );
  const highlighterOptions = workerHighlighterOptions(options, appearance, ["text"]);
  const [workerPoolOptions] = useState(() => createDiffWorkerPoolOptions());
  const [prepared] = useState(() => preparePresortedFileTreeInput(files.map((file) => file.path)));
  const { model } = useFileTree({
    flattenEmptyDirectories: true,
    id: "cmux-diff-file-tree",
    initialExpansion: "open",
    density: "compact",
    itemHeight: 22,
    overscan: 12,
    preparedInput: prepared,
    sort: () => 0,
    gitStatus: files.map((file) => ({ path: file.path, status: file.status })) as any,
  });
  return (
    <div style={{ display: "grid", gridTemplateColumns: "280px 1fr", height: "100vh" }}>
      <FileTree model={model} style={{ height: "100%" }} />
      <WorkerPoolContextProvider poolOptions={workerPoolOptions} highlighterOptions={highlighterOptions}>
        <CodeView
          ref={codeView}
          className="code-view-root"
          style={{ height: "100vh", overflow: "auto" }}
          initialItems={initialItems}
          options={codeViewOptions(options, appearance)}
          renderCustomHeader={(item) => {
            // The virtualizer renders headers only for items in or near the viewport, so a
            // header render is the "this file is visible" signal that drives the hunk loads.
            if ((item as any).version === 0) loader.request(item.id);
            return <div style={{ padding: "6px 10px", font: "12px system-ui" }}>{item.id}</div>;
          }}
        />
      </WorkerPoolContextProvider>
    </div>
  );
}

export type { LazyStats };
