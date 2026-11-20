// Owns syncing the highlight worker pool's render options with the viewer's theme and options.
import {
  type DiffsTheme,
  getHighlighterIfLoaded,
  getThemes,
  renderDiffWithHighlighter,
  renderFileWithHighlighter,
  resolveThemes,
} from "@pierre/diffs";
import { type CodeViewHandle, useWorkerPool } from "@pierre/diffs/react";
import { useEffect, useRef } from "react";
import { createCssVariablesTheme, createHighlighter, createJavaScriptRegexEngine } from "shiki";
import { workerHighlighterOptions } from "../pierre-options";

type WorkerPool = NonNullable<ReturnType<typeof useWorkerPool>>;
type PlainHighlighter = Parameters<typeof renderDiffWithHighlighter>[1];
type PlainDrawingPool = Pick<WorkerPool, "getPlainDiffAST" | "getPlainFileAST">;

/**
 * Lets the highlight pool draw a file's rows as plain text before its highlighter is up.
 *
 * The pool draws plain rows (`getPlainDiffAST`, `getPlainFileAST`) with the page's shared
 * highlighter, which it loads only as it starts its workers (Shiki on the WASM engine, compiled on
 * the page); until then a file draws its header and no rows. On a big diff that was 300 to 450 ms
 * after the first files were parsed. Plain rows need only the two themes' colors and Shiki's "text"
 * language, which tokenizes nothing, so this builds a small Shiki instance on the JavaScript engine
 * (already in the bundle; no WASM, no grammar) right away and, while the pool has no highlighter
 * of its own, draws the plain rows with it through the package's own renderer
 * (`renderDiffWithHighlighter`). The rows are the package's rows, at its heights and places, so
 * nothing moves when the pool's own plain rows and then the colors replace them. The pool's
 * methods run first and win as soon as its shared highlighter has the themes; once the pool is up
 * (or stopped) its methods are put back and this instance is disposed. `@pierre/diffs` is pinned
 * (package.json); diff-paint-perf.test.ts fails if a new version stops drawing rows before the
 * workers start. The themes are the pool's own (the ones it draws plain rows with), not the
 * viewer's options, which may have changed since the pool was created. Resolves `drawn` when the
 * plain rows draw with this instance, `ready` when the pool was up first, `stopped` when the pool
 * was shut down (the viewer unmounted) and `unsupported` when the pool no longer draws plain rows
 * where this hooks in.
 */
export async function drawPlainBeforeWorkers(pool: WorkerPool): Promise<PlainBeforeWorkers> {
  const target = pool as unknown as PlainDrawingPool;
  if (typeof target.getPlainDiffAST !== "function" || typeof target.getPlainFileAST !== "function") {
    return "unsupported";
  }
  const poolReady = () =>
    pool.isInitialized() || getHighlighterIfLoaded({ theme: pool.getDiffRenderOptions().theme }) != null;
  if (poolReady()) {
    return "ready";
  }
  const themes = await resolveThemes(getThemes(pool.getDiffRenderOptions().theme), pool.getPreferredHighlighter());
  const raw = await createHighlighter({
    themes: themes.map((theme) => ({ ...shikiTheme(theme), name: theme.name })),
    langs: [],
    engine: createJavaScriptRegexEngine(),
  });
  if (poolReady()) {
    raw.dispose();
    return "ready";
  }
  // Shut down while this was built (the viewer unmounted): nothing would release it.
  if (poolStopped(pool)) {
    raw.dispose();
    return "stopped";
  }
  const themeByName = new Map(themes.map((theme) => [theme.name, theme]));
  let released = false;
  // What the package's renderers read of a highlighter when they draw plain text.
  const plain = {
    name: "shiki-js",
    getTheme(name: string): DiffsTheme {
      const theme = themeByName.get(name);
      if (theme == null) throw new Error(`plain rows: theme "${name}" is not loaded`);
      return theme;
    },
    codeToTokens: (code: string, options: Parameters<typeof raw.codeToTokens>[1]) => raw.codeToTokens(code, options),
  } as unknown as PlainHighlighter;
  /** Only while alive and holding the pool's current themes (a theme change waits for the pool). */
  const usable = () => !released && getThemes(pool.getDiffRenderOptions().theme).every((name) => themeByName.has(name));
  const ownDiff = target.getPlainDiffAST;
  const ownFile = target.getPlainFileAST;
  const drawDiff: WorkerPool["getPlainDiffAST"] = (
    diff,
    startingLine,
    totalLines,
    expandedHunks,
    collapsedContextThreshold,
  ) => {
    // The pool's own call also queues its start-up when it has no highlighter yet.
    const own = ownDiff.call(pool, diff, startingLine, totalLines, expandedHunks, collapsedContextThreshold);
    if (own != null || !usable()) return own;
    return renderDiffWithHighlighter(diff, plain, pool.getDiffRenderOptions(), {
      forcePlainText: true,
      startingLine,
      totalLines,
      expandedHunks,
      collapsedContextThreshold,
    });
  };
  const drawFile: WorkerPool["getPlainFileAST"] = (file, startingLine, totalLines, lines) => {
    const own = ownFile.call(pool, file, startingLine, totalLines, lines);
    if (own != null || !usable()) return own;
    return renderFileWithHighlighter(file, plain, pool.getFileRenderOptions(), {
      forcePlainText: true,
      startingLine,
      totalLines,
      lines,
    });
  };
  target.getPlainDiffAST = drawDiff;
  target.getPlainFileAST = drawFile;
  // The pool broadcasts its stats once it is up or stopped: its own methods come back, then dispose.
  let unsubscribe: (() => void) | null = null;
  const releaseWhenDone = () => {
    if (released || !(pool.isInitialized() || poolStopped(pool))) return;
    released = true;
    unsubscribe?.();
    if (target.getPlainDiffAST === drawDiff) target.getPlainDiffAST = ownDiff;
    if (target.getPlainFileAST === drawFile) target.getPlainFileAST = ownFile;
    raw.dispose();
  };
  unsubscribe = pool.subscribeToStatChanges(releaseWhenDone);
  if (released) unsubscribe();
  return "drawn";
}

/** The Shiki theme inside a resolved Pierre theme (a TextMate theme, or one drawn with CSS variables). */
function shikiTheme(theme: DiffsTheme) {
  if (theme.textmate != null) return theme.textmate;
  if (theme.cssVariables != null) return createCssVariablesTheme(theme.cssVariables);
  throw new Error(`plain rows: theme "${theme.name}" has no Shiki theme`);
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
  codeViewRef: React.MutableRefObject<CodeViewHandle<any, any> | null>;
  highlighterOptions: ReturnType<typeof workerHighlighterOptions>;
}) {
  useWorkerRenderOptionsSync(highlighterOptions, codeViewRef);
  useDrawPlainBeforeWorkers(codeViewRef);
  return null;
}

function useDrawPlainBeforeWorkers(codeViewRef: React.MutableRefObject<CodeViewHandle<any, any> | null>): void {
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
  codeViewRef: React.MutableRefObject<CodeViewHandle<any, any> | null>,
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
