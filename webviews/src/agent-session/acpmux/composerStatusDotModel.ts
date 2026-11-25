import { readComposerStatus } from "./composerStatusModel";
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
