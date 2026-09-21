import type { AuthedUser } from "./auth";

export const VIEW_LEASE_MS = 45_000;
export const VIEW_RENEW_MS = 15_000;
export const MAX_VIEW_SOCKETS = 128;
export const VIEW_AUTH_MS = 15 * 60_000;

export interface WorkspaceScope {
  kind: "cloud" | "mac";
  ownerID: string;
  instanceTag?: string;
  workspaceID: string;
  teamID?: string;
}
export interface ViewerIdentity {
  id: string;
  displayName?: string;
  avatarURL?: string;
}
export interface ViewerLease {
  identity: ViewerIdentity;
  expiresAt: number;
  viewingUntil: number;
  scope: WorkspaceScope;
}
const validID = (raw: unknown, limit = 128): raw is string =>
  typeof raw === "string" && raw.length <= limit && /^[A-Za-z0-9._-]+$/.test(raw);
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Strict, canonical room identity; no delimiter concatenation of untrusted ids. */
export function parseWorkspaceScope(raw: unknown): WorkspaceScope | null {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  const s = raw as Record<string, unknown>;
  if (Object.keys(s).some((key) => !["kind", "ownerID", "instanceTag", "workspaceID", "teamID"].includes(key))) return null;
  if (!validID(s.ownerID) || !validID(s.workspaceID)) return null;
  if (s.kind === "cloud" && validID(s.teamID) && s.instanceTag == null) {
    return { kind: "cloud", ownerID: s.ownerID, workspaceID: s.workspaceID, teamID: s.teamID };
  }
  if (s.kind === "mac" && validID(s.instanceTag, 64) && s.teamID == null
      && uuid.test(s.ownerID) && uuid.test(s.workspaceID)) {
    return { kind: "mac", ownerID: s.ownerID.toLowerCase(), instanceTag: s.instanceTag, workspaceID: s.workspaceID.toLowerCase() };
  }
  return null;
}

/** An on-device room is account-private; Cloud rooms belong to a verified team. */
export function workspaceRoom(scope: WorkspaceScope, user: AuthedUser): string | null {
  if (scope.kind === "cloud" && !user.teamIds.includes(scope.teamID!) && scope.teamID !== user.id) return null;
  return JSON.stringify(["workspace-presence-v1", scope.kind === "mac" ? user.id : scope.teamID, scope]);
}

/** Profile metadata is bounded and comes only from Stack, never socket messages. */
export function viewerIdentity(user: AuthedUser): ViewerIdentity {
  const displayName = user.displayName?.replace(/[\u0000-\u001f\u007f]/g, "").trim().slice(0, 128);
  let avatarURL: string | undefined;
  try {
    const url = new URL(user.profileImageURL ?? "");
    if (url.protocol === "https:" && !url.username && !url.password && url.href.length <= 2048) avatarURL = url.href;
  } catch { /* Missing images render an initial or person glyph. */ }
  return { id: user.id, ...(displayName ? { displayName } : {}), ...(avatarURL ? { avatarURL } : {}) };
}

/** Only active state is mutable; identity, room, and auth deadline stay pinned. */
export function renewViewer(lease: ViewerLease, active: boolean, now: number): ViewerLease {
  return { ...lease, viewingUntil: active ? Math.min(now + VIEW_LEASE_MS, lease.expiresAt) : 0 };
}

/** Deduplicate multiple live devices without reordering avatars on lease ticks. */
export function workspaceViewers(leases: readonly ViewerLease[], now: number): ViewerIdentity[] {
  const users = new Map<string, ViewerIdentity>();
  for (const lease of leases) {
    if (lease.expiresAt > now && lease.viewingUntil > now) users.set(lease.identity.id, lease.identity);
  }
  return [...users.values()].sort((a, b) => a.id.localeCompare(b.id));
}

export function parseViewing(message: string | ArrayBuffer): boolean | null {
  if (typeof message !== "string" || message.length > 256) return null;
  try {
    const value = JSON.parse(message) as Record<string, unknown>;
    return value && Object.keys(value).length === 2 && value.type === "view" && typeof value.active === "boolean" ? value.active : null;
  } catch { return null; }
}
