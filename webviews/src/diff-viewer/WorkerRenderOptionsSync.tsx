// Owns syncing the highlight worker pool's render options with the viewer's theme and options.
import { getThemes, resolveThemes } from "@pierre/diffs";
import { type CodeViewHandle, useWorkerPool } from "@pierre/diffs/react";
import { useEffect, useRef } from "react";
import { createHighlighter, createJavaScriptRegexEngine } from "shiki";
import { workerHighlighterOptions } from "../pierre-options";

type WorkerPool = NonNullable<ReturnType<typeof useWorkerPool>>;
type PlainDrawingPool = { highlighter?: unknown; isInitialized(): boolean };

/**
 * Lets the highlight pool draw a file's rows as plain text before its workers are up.
 *
 * The pool draws plain rows (`getPlainDiffAST`) with the page's Shiki instance, which it keeps
 * only once every worker has started and the page has compiled Shiki's WASM engine too; until
 * then a file draws its header and no rows. On a big diff that was 300 to 450 ms after the first
 * files were parsed. Plain rows need only the two themes' colors and Shiki's "text" language,
 * which tokenizes nothing, so this hands the pool a small instance on the JavaScript engine
 * (already in the bundle; no WASM, no grammar) right away. The pool replaces it with its own when
 * its start-up finishes, and the colors arrive as the workers answer. `@pierre/diffs` is pinned
 * (package.json); diff-paint-perf.test.ts fails if a new version stops drawing rows before the
 * workers start. The themes are the pool's own (the ones it draws plain rows with), not the
 * viewer's options, which may have changed since the pool was created. Resolves `drawn` when it
 * handed the instance over, `ready` when the pool was up first, `stopped` when the pool was shut
 * down (the viewer unmounted) and `unsupported` when the pool no longer keeps its instance where
 * this reads it.
 */
export async function drawPlainBeforeWorkers(pool: WorkerPool): Promise<PlainBeforeWorkers> {
  const target = pool as unknown as PlainDrawingPool;
  if (!("highlighter" in target)) {
    return "unsupported";
  }
  if (pool.isInitialized() || target.highlighter != null) {
    return "ready";
  }
  const themes = await resolveThemes(getThemes(pool.getDiffRenderOptions().theme));
  const highlighter = await createHighlighter({ themes, langs: [], engine: createJavaScriptRegexEngine() });
  if (target.isInitialized() || target.highlighter != null) {
    highlighter.dispose();
    return "ready";
  }
  // Shut down while this was built (the viewer unmounted): nothing would replace or dispose it.
  if (poolStopped(pool)) {
    highlighter.dispose();
    return "stopped";
  }
  target.highlighter = highlighter;
  // The pool replaces it with its own once the workers are up (or clears it when terminated)
  // without disposing it; the pool broadcasts its stats after either, so it is disposed then.
  let unsubscribe: (() => void) | null = null;
  let disposed = false;
  const releaseWhenReplaced = () => {
    if (disposed || target.highlighter === highlighter) return;
    disposed = true;
    unsubscribe?.();
    highlighter.dispose();
  };
  unsubscribe = pool.subscribeToStatChanges(releaseWhenReplaced);
  if (disposed) unsubscribe();
  return "drawn";
}

export type PlainBeforeWorkers = "drawn" | "ready" | "stopped" | "unsupported";

/** The pool was terminated (`terminate()`), not failed: it has no workers and no instance. */
function poolStopped(pool: WorkerPool): boolean {
  const stats = pool.getStats();
  return stats.managerState === "waiting" && !stats.workersFailed;
}

export function WorkerRenderOptionsSync({
  codeViewRef,
  highlighterOptions,
}: {
  codeViewRef: React.MutableRefObject<CodeViewHandle<any> | null>;
  highlighterOptions: ReturnType<typeof workerHighlighterOptions>;
}) {
  useWorkerRenderOptionsSync(highlighterOptions, codeViewRef);
  useDrawPlainBeforeWorkers(codeViewRef);
  return null;
}

function useDrawPlainBeforeWorkers(codeViewRef: React.MutableRefObject<CodeViewHandle<any> | null>): void {
  const workerPool = useWorkerPool();
  useEffect(() => {
    if (!workerPool) {
      return;
    }
    let active = true;
    drawPlainBeforeWorkers(workerPool)
      .then((outcome) => {
        // Read by diff-paint-perf.test.ts, as the pool's counters are (worker-pool.ts).
        document.documentElement.dataset.cmuxDiffPlainBeforeWorkers = outcome;
        // Files that drew before the instance arrived (no rows) draw again, as plain text.
        if (active && outcome === "drawn") codeViewRef.current?.getInstance()?.render(true);
      })
      .catch((error: unknown) => console.warn("cmux diff plain rows before the highlight workers failed", error));
    return () => {
      active = false;
    };
  }, [codeViewRef, workerPool]);
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
    workerPool
      .setRenderOptions(highlighterOptions)
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
  return (
    // `langs` only seed the pool at creation; the pool loads each file's grammar with its task,
    // so a newly seen language must not force a full re-render.
    previous?.lineDiffType === next.lineDiffType &&
    previous?.maxLineDiffLength === next.maxLineDiffLength &&
    previous?.preferredHighlighter === next.preferredHighlighter &&
    sameThemeOption(previous?.theme, next.theme) &&
    previous?.tokenizeMaxLineLength === next.tokenizeMaxLineLength &&
    previous?.useTokenTransformer === next.useTokenTransformer
  );
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
  return (
    (previous as { dark?: string }).dark === (next as { dark?: string }).dark &&
    (previous as { light?: string }).light === (next as { light?: string }).light
  );
}
