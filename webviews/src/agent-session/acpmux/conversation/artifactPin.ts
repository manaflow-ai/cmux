// A preview normally belongs to the active chat. Pin keeps its document visible when the
// reader switches chats, without treating another chat's replies as this document's versions.
// These are UI-only snapshots: app restart and cross-device retention belong to Artifacts.
import type { Artifact } from "./artifactPreview";

export type OpenedArtifact = Artifact & {
  sessionId?: string;
  opened: number;
  pinned?: boolean;
  /** The source chat's known versions at the moment of Pin. Never read a different chat's rows. */
  pinVersions?: readonly Artifact[];
};

/** An unpinned document closes when the active session changes. */
export function visibleArtifact(opened: OpenedArtifact | undefined, sessionId: string | undefined): OpenedArtifact | undefined {
  return opened && (opened.sessionId === sessionId || opened.pinned) ? opened : undefined;
}

/** Pin preserves source versions; Unpin from another chat closes instead of reattributing the pane. */
export function changeArtifactPin(
  opened: OpenedArtifact | undefined,
  pinned: boolean,
  activeSession: string | undefined,
  versions?: readonly Artifact[],
): OpenedArtifact | undefined {
  if (!opened) return undefined;
  if (!pinned && opened.sessionId !== activeSession) return undefined;
  // Without an owning chat, the user cannot pin a document with reliable provenance.
  if (pinned && (!opened.sessionId || opened.sessionId !== activeSession)) return opened;
  return {
    ...opened,
    pinned,
    pinVersions: pinned ? [...(versions?.length ? versions : [opened])] : undefined,
  };
}

/** Only the owning chat can supply live revisions; elsewhere use the last accepted snapshot. */
export function artifactVersionsForSession(
  opened: OpenedArtifact | undefined,
  activeSession: string | undefined,
  liveVersions?: readonly Artifact[],
): readonly Artifact[] | undefined {
  if (!opened) return undefined;
  if (opened.sessionId !== activeSession)
    return opened.pinned ? (opened.pinVersions ?? [opened]) : undefined;
  return liveVersions ?? (opened.pinned ? (opened.pinVersions ?? [opened]) : undefined);
}
