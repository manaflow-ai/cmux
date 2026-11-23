import { holdWebSwap } from "../../../pages/shared/webSwap";
import { callNative } from "../callNative";
import { type ScrollAnchor } from "../VirtualTranscript";

/// Where chat `sessionId` rests, kept by its tab so a relaunch reopens it there (cx-6bgzj): the host
/// knows the pane's tab and keeps the place under it (AgentPaneScrollAnchors.swift).
export const postScrollAnchor = (sessionId: string, anchor: ScrollAnchor | null) => {
  const place = { sessionId, rowId: anchor?.rowId ?? null, offset: anchor?.offset ?? 0 };
  const write = anchorWrites.get(sessionId) ?? {
    sent: 0,
    kept: 0,
    inFlight: 0,
    failed: false,
    place,
  };
  write.place = place;
  anchorWrites.set(sessionId, write);
  sendScrollAnchor(write);
};
type AnchorWrite = {
  /// The newest place sent and the newest one the host answered for (`kept` behind `sent`: not kept yet).
  sent: number;
  kept: number;
  inFlight: number;
  /// The newest write was refused: the next ask sends it again.
  failed: boolean;
  place: { sessionId: string; rowId: string | null; offset: number };
};
/// Per chat, so one chat's write never stands in for another's.
const anchorWrites = new Map<string, AnchorWrite>();
const sendScrollAnchor = (write: AnchorWrite) => {
  const n = ++write.sent;
  write.failed = false;
  write.inFlight += 1;
  void callNative("chat.scrollAnchor", write.place)
    .then(
      () => {
        if (n === write.sent) write.kept = n;
      },
      () => {
        if (n === write.sent) write.failed = true;
      },
    )
    .finally(() => {
      write.inFlight -= 1;
    });
};
// WEB-SWAP: a web update's reload reopens the chat at the kept place, so it waits for the newest
// one to be kept. A refused one goes again on the next ask (pages/shared/webSwap.ts).
holdWebSwap(() => {
  let reason: string | null = null;
  for (const write of anchorWrites.values()) {
    if (write.kept >= write.sent) continue;
    if (write.failed && write.inFlight === 0) sendScrollAnchor(write);
    reason = "transcript.place-unsaved";
  }
  return reason;
});
/// A host that does not answer `chat.scrollAnchor.get` (the gallery, an older app) never holds up the chat.
const SCROLL_ANCHOR_READ_MS = 250;

/// Where chat `sessionId` rested when it was last shown; undefined when nothing is kept.
const fetchScrollAnchor = async (sessionId: string): Promise<(ScrollAnchor & { sessionId: string }) | undefined> => {
  const anchor = await Promise.race([
    callNative<{ rowId?: unknown; offset?: unknown } | null>("chat.scrollAnchor.get", {
      sessionId,
    }).catch(() => null),
    new Promise<null>((resolve) => setTimeout(() => resolve(null), SCROLL_ANCHOR_READ_MS)),
  ]);
  return typeof anchor?.rowId === "string" && typeof anchor.offset === "number"
    ? { sessionId, rowId: anchor.rowId, offset: anchor.offset }
    : undefined;
};

export { fetchScrollAnchor };
