import { readComposerStatus, statusWordsKey } from "./composerStatusModel";
import type { PeerLinkDetail } from "./linkState";

/// What the composer passes: the chat's snapshot pieces the dot reads (ComposerStatusDot.tsx).
export type StatusSnapshot = {
  summary?: { peer?: string; composerStatus?: unknown } | undefined;
  peerLinks?: Record<string, PeerLinkDetail> | undefined;
};

/// Whether the chat gets the dot: every chat but a remote one from an older acpmux, which says
/// neither `composerStatus` nor a link `status` (MachineLinkStatus keeps that one's row).
export function statusDotMounts(snapshot: StatusSnapshot): boolean {
  const peer = snapshot.summary?.peer;
  if (!peer) return true;
  return readComposerStatus(snapshot.summary?.composerStatus) !== undefined || !!snapshot.peerLinks?.[peer]?.status;
}

/// Whether the dot says the chat's queue is paused (acpmux's `queuePaused` item, with its Resume):
/// then the queue's own paused note stays out (ComposerQueue `pauseSaid`). An older acpmux sends no
/// item and a remote chat from one gets no dot: the note says it as before.
export function dotSaysQueuePaused(snapshot: StatusSnapshot): boolean {
  if (!statusDotMounts(snapshot)) return false;
  const items = readComposerStatus(snapshot.summary?.composerStatus)?.items ?? [];
  return items.some((item) => item.kind === "queuePaused" && statusWordsKey(item) !== undefined);
}
