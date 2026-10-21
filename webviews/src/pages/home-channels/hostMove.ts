// `home.moveConversation` {delta: 1 | -1} -> {moved: boolean}: the host's previous/next
// conversation (Cmd-Shift-[ / ], `home.previousConversation` / `home.nextConversation`) while the
// docked Home shows Channels. It runs the page's own list move (Option-Up/Down), so the order is
// the one the list shows. A page without the op answers `cmux.protocol.unknown_op`.
import { useEffect, useLayoutEffect, useRef } from "react";
import type { PageClient } from "../shared/pageClient";

export const MOVE_CONVERSATION_OP = "home.moveConversation";

/** Opens the conversation `delta` rows away in the list; true when one opened. */
export type HostMove = (delta: 1 | -1) => boolean;

/** Serves the op on `host`, running the move `latest` returns at call time. Returns the stop. */
export function serveHostMove(host: PageClient, latest: () => HostMove): () => void {
  return host.handle(MOVE_CONVERSATION_OP, (params) => {
    const delta = (params as { delta?: unknown } | null | undefined)?.delta;
    if (delta !== 1 && delta !== -1) return { moved: false };
    return { moved: latest()(delta) };
  });
}

/** Serves `home.moveConversation` while the page is mounted, with the latest committed move. */
export function useHostMove(host: PageClient | null, move: HostMove): void {
  const latest = useRef(move);
  useLayoutEffect(() => {
    latest.current = move;
  }, [move]);
  useEffect(() => {
    if (!host) return;
    return serveHostMove(host, () => latest.current);
  }, [host]);
}
