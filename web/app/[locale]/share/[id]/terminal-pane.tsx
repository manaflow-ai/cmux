"use client";

import { useCallback, useRef } from "react";
import type { Terminal as GhosttyTerminal } from "ghostty-web";
import { loadGhostty } from "./ghostty";
import type { SurfaceSink, SurfaceStore } from "./surface-store";

const TERMINAL_THEME = {
  background: "#0d0e12",
  foreground: "#d8dbe2",
};

/**
 * A read-only ghostty-web terminal attached to one shared surface. The
 * terminal mounts through a callback ref: on attach we lazily init the
 * wasm module, create the Terminal, and register a sink with the
 * SurfaceStore (which replays any buffered snapshot/live chunks). No
 * onData wiring — viewers cannot type.
 */
export function TerminalPane({
  surfaceId,
  cols,
  rows,
  fontSize,
  store,
}: {
  surfaceId: string;
  cols: number;
  rows: number;
  fontSize: number;
  store: SurfaceStore;
}) {
  const cleanupRef = useRef<(() => void) | null>(null);

  const hostRef = useCallback(
    (node: HTMLDivElement | null) => {
      cleanupRef.current?.();
      cleanupRef.current = null;
      if (!node) return;

      let disposed = false;
      let terminal: GhosttyTerminal | null = null;
      let sink: SurfaceSink | null = null;

      void loadGhostty()
        .then((mod) => {
          if (disposed) return;
          terminal = new mod.Terminal({
            cols,
            rows,
            fontSize,
            disableStdin: true,
            cursorBlink: false,
            scrollback: 2000,
            theme: TERMINAL_THEME,
          });
          terminal.open(node);
          const term = terminal;
          sink = {
            write: (bytes) => term.write(bytes),
            resize: (nextCols, nextRows) => term.resize(nextCols, nextRows),
          };
          store.attach(surfaceId, sink);
        })
        .catch((error) => {
          console.error("[share] failed to init ghostty-web", error);
        });

      cleanupRef.current = () => {
        disposed = true;
        if (sink) store.detach(surfaceId, sink);
        terminal?.dispose();
        terminal = null;
        sink = null;
      };
    },
    // The pane identity (surfaceId) owns this terminal; geometry changes
    // are handled through term_resize messages, not remounts.
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [surfaceId, store],
  );

  return (
    <div
      ref={hostRef}
      className="h-full w-full overflow-hidden"
      style={{ background: TERMINAL_THEME.background }}
    />
  );
}
