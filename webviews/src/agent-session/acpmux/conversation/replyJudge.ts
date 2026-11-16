// The detector for a reply the chat holds but does not paint (replyPainted.ts), as the transcript runs it: once a
// turn this page watched has ended and the page has settled, the followed view must show its final reply, or the
// flicker ring file says why (`reply-unpainted`). Each reply is judged once.
//
// Only a turn whose end this page saw is judged (Leo, 2026-11-12: "you should be able to detect that the messages
// aren't coming out from the coordinator"). A chat opened or switched to at rest ended its turn long before: judging
// it armed a REPLY_SETTLE_MS timer on every switch, which woke the pane at rest (CMUX-571, idle wakeups:
// bench/chat-switch.bench.ts idle_wakeups; Leo: "Infinite everything feels like nothing").
import { useEffect, useRef, type RefObject } from "react";
import type { AcpmuxRow } from "../model";
import { noteReplyUnpainted } from "../flickerLog";
import { finalReplyId, REPLY_SETTLE_MS, replyUnpainted } from "./replyPainted";

export type EndedReplyCheck = {
  rows: readonly AcpmuxRow[];
  sessionId: string | undefined;
  working: boolean;
  loading: boolean;
  /// The dock's room under the rows (px): the followed view ends above it.
  dockSpace: number;
  scroller: RefObject<HTMLElement | null>;
  host: RefObject<HTMLElement | null>;
  /// Whether the reader follows the newest row.
  follow: RefObject<{ atLatest: boolean }>;
};

export function useEndedReplyCheck({
  rows,
  sessionId,
  working,
  loading,
  dockSpace,
  scroller,
  host,
  follow,
}: EndedReplyCheck): void {
  const judged = useRef<string | undefined>(undefined);
  // The chat whose turn this page saw working; its next end is judged.
  const watched = useRef<string | undefined>(undefined);
  useEffect(() => {
    // Another chat shown: the turn this page watched was that chat's.
    if (watched.current !== sessionId) watched.current = undefined;
    if (working) {
      watched.current = sessionId;
      return;
    }
    if (loading || !sessionId || watched.current !== sessionId) return;
    const id = finalReplyId(rows);
    if (!id || judged.current === id) return;
    const timer = window.setTimeout(() => {
      const view = scroller.current;
      const thread = host.current;
      if (!view || !thread || document.visibilityState !== "visible" || !following(follow)) return;
      judged.current = id;
      const name = typeof CSS === "undefined" ? id.replace(/["\\]/g, "\\$&") : CSS.escape(id);
      const node = thread.querySelector<HTMLElement>(`.acpmux-row[data-row-id="${name}"]`);
      const box = view.getBoundingClientRect();
      const why = replyUnpainted(node, thread, { top: box.top, bottom: box.bottom - dockSpace });
      if (why) noteReplyUnpainted(why, Math.round(node?.getBoundingClientRect().height ?? 0));
    }, REPLY_SETTLE_MS);
    return () => window.clearTimeout(timer);
  }, [rows, sessionId, working, loading, dockSpace, scroller, host, follow]);
}

/// Whether the reader follows the newest row now, read when the check runs.
const following = (follow: RefObject<{ atLatest: boolean }>) => follow.current.atLatest;
