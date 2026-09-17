export const SHARE_TTL_MS = 8 * 60 * 60 * 1_000;
export const HOST_RECONNECT_GRACE_MS = 2 * 60 * 1_000;
export const HOST_INITIAL_CONNECT_GRACE_MS = 2 * 60 * 1_000;
export const MAX_VIEWERS = 24;
export const MAX_PENDING_VIEWERS = 24;
export const MAX_DENIED_VIEWERS = 64;
export const PARTICIPANT_COLORS = 12;

export type ShareOwner = {
  readonly userId: string;
  readonly email: string;
  readonly displayName: string;
};

export type ShareRoomMetadata = {
  readonly shareId: string;
  readonly owner: ShareOwner;
  readonly hostCapabilityHash: string;
  readonly workspaceId: string;
  readonly workspaceTitle: string;
  readonly createdAt: number;
  readonly expiresAt: number;
  readonly status: "active" | "ended";
  readonly hostConnectedAt?: number;
  readonly hostDisconnectedAt?: number;
};

export type ViewerAccess = "pending" | "approved" | "denied";

export type ViewerState = {
  readonly userId: string;
  readonly email: string;
  readonly displayName: string;
  readonly color: number;
  readonly access: ViewerAccess;
  readonly requestedAt: number;
  readonly decidedAt?: number;
};

export function normalizeShareId(value: string): string | null {
  return /^[A-Za-z0-9_-]{22}$/.test(value) ? value : null;
}

export function shareExpiry(createdAt: number): number {
  return createdAt + SHARE_TTL_MS;
}

export function hostReconnectDeadline(metadata: ShareRoomMetadata): number {
  if (metadata.hostConnectedAt === undefined) {
    return Math.min(metadata.expiresAt, metadata.createdAt + HOST_INITIAL_CONNECT_GRACE_MS);
  }
  return Math.min(
    metadata.expiresAt,
    metadata.hostDisconnectedAt === undefined
      ? metadata.expiresAt
      : metadata.hostDisconnectedAt + HOST_RECONNECT_GRACE_MS,
  );
}

export function hostIsUnavailable(metadata: ShareRoomMetadata): boolean {
  return metadata.hostConnectedAt === undefined || metadata.hostDisconnectedAt !== undefined;
}

export function hostAvailabilityExpired(metadata: ShareRoomMetadata, now: number): boolean {
  return hostIsUnavailable(metadata) && hostReconnectDeadline(metadata) <= now;
}

export function nextRoomAlarm(metadata: ShareRoomMetadata): number {
  return hostIsUnavailable(metadata) ? hostReconnectDeadline(metadata) : metadata.expiresAt;
}

export function viewerConnectionExpiry(
  access: ViewerAccess,
  roomExpiresAt: number,
  ticketExpiresAt: number,
): number {
  return access === "approved" ? roomExpiresAt : Math.min(roomExpiresAt, ticketExpiresAt);
}

export function pendingViewerTicketIsFresh(ticketExpiresAt: number | undefined, now: number): boolean {
  return ticketExpiresAt !== undefined && Number.isSafeInteger(ticketExpiresAt) && ticketExpiresAt > now;
}

export function colorForUser(userId: string): number {
  let hash = 2_166_136_261;
  for (const byte of new TextEncoder().encode(userId)) {
    hash ^= byte;
    hash = Math.imul(hash, 16_777_619);
  }
  return Math.abs(hash) % PARTICIPANT_COLORS;
}

export function decideViewer(
  viewer: ViewerState,
  decision: "allow" | "deny",
  now: number,
): ViewerState {
  if (viewer.access !== "pending") return viewer;
  return {
    ...viewer,
    access: decision === "allow" ? "approved" : "denied",
    decidedAt: now,
  };
}

export function canCreateViewer(
  viewers: readonly ViewerState[],
): "ok" | "room_full" | "too_many_pending" {
  if (viewers.filter((viewer) => viewer.access === "pending").length >= MAX_PENDING_VIEWERS) {
    return "too_many_pending";
  }
  const activeViewers = viewers.filter((viewer) => viewer.access !== "denied");
  if (activeViewers.length >= MAX_VIEWERS) {
    return "room_full";
  }
  return "ok";
}
