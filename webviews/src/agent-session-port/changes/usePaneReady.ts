// Readiness of a ChangesPane, built from the events its renderers already emit. No
// effects and no frame polling: each signal is a Pierre callback or a callback ref.
//
//   diff painted   @pierre/diffs onPostRender for every file
//   header mounted the custom header's callback ref for every file (Pierre renders the
//                  header slot only after it has computed the diff, after its first paint)
//   pane committed the pane root's callback ref; the Pierre tree renders in a layout
//                  effect of its own, so it has drawn its rows by then
//
// When all three hold for the current file list the pane is ready: it calls `onReady` once
// and releases its hold on window.__atlasReady (src/conversation/ready.ts, registered at
// first commit), so screens need no readiness plumbing of their own. Overlays need no
// signal: CSS positions them against these anchors at layout time.
//
// useStableCallback (from @pierre/diffs) keeps the handlers' identity stable so React does
// not detach and re-attach the callback refs on every render.
import { useRef } from "react";
import { useStableCallback } from "@pierre/diffs/react";
import { trackRender } from "../conversation/ready";

export interface PaneReadiness {
  diffPainted(path: string): void;
  headerMounted(path: string, el: HTMLElement | null): void;
  /** Callback ref for the pane root. */
  paneRef(el: HTMLElement | null): void;
}

export function usePaneReady(paths: readonly string[], onReady?: () => void): PaneReadiness {
  const seen = useRef({
    painted: new Set<string>(),
    headers: new Set<string>(),
    committed: false,
    fired: false,
    release: (() => {}) as () => void,
  });
  const check = useStableCallback(() => {
    const s = seen.current;
    if (s.fired || !s.committed) return;
    if (!paths.every((p) => s.painted.has(p) && s.headers.has(p))) return;
    s.fired = true;
    s.release();
    onReady?.();
  });
  return {
    diffPainted: useStableCallback((path: string) => {
      seen.current.painted.add(path);
      check();
    }),
    headerMounted: useStableCallback((path: string, el: HTMLElement | null) => {
      if (!el) return;
      seen.current.headers.add(path);
      check();
    }),
    paneRef: useStableCallback((el: HTMLElement | null) => {
      const s = seen.current;
      if (!el || s.committed) return;
      s.committed = true;
      s.release = trackRender();
      check();
    }),
  };
}
