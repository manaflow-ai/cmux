// The detector for a reply the chat holds but does not paint (replyPainted.ts), as the transcript runs it: once the
// turn has ended and the page has settled, the followed view must show its final reply, or the flicker ring file says
// why (`reply-unpainted`). Each reply is judged once.
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
  atLatest: () => boolean;
};

export function useEndedReplyCheck({
  rows,
  working,
  loading,
  dockSpace,
  scroller,
  host,
  atLatest,
}: EndedReplyCheck): void {
  const judged = useRef<string | undefined>(undefined);
  const follows = useRef(atLatest);
  follows.current = atLatest;
  useEffect(() => {
    if (working || loading) return;
    const id = finalReplyId(rows);
    if (!id || judged.current === id) return;
    const timer = window.setTimeout(() => {
      const view = scroller.current;
      const thread = host.current;
      if (!view || !thread || document.visibilityState !== "visible" || !follows.current()) return;
      judged.current = id;
      const name = typeof CSS === "undefined" ? id.replace(/["\\]/g, "\\$&") : CSS.escape(id);
      const node = thread.querySelector<HTMLElement>(`.acpmux-row[data-row-id="${name}"]`);
      const box = view.getBoundingClientRect();
      const why = replyUnpainted(node, thread, { top: box.top, bottom: box.bottom - dockSpace });
      if (why) noteReplyUnpainted(why, Math.round(node?.getBoundingClientRect().height ?? 0));
    }, REPLY_SETTLE_MS);
    return () => window.clearTimeout(timer);
  }, [rows, working, loading, dockSpace, scroller, host]);
}
