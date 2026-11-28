import { createHash, randomBytes } from "node:crypto";
import type { TeamAccess } from "./access";
import { TeamApiError } from "./errors";
import { acceptEmailInvitationToken, previewEmailInvitationToken } from "./received";
import { assertSeatsAvailable } from "./seats";
import { databaseTeamInviteStore, type StoredInviteLink, type TeamInviteStore } from "./repository";
import { defaultTeamSeatSync, type TeamSeatSync } from "./seatSync";
import {
  defaultTeamStackApp,
  isTeamMembershipAlreadyExists,
  withStackDeadline,
  type TeamStackApp,
} from "./stack";
import type { TeamInviteLink } from "./types";

export const INVITE_LINK_EXPIRY_DAYS = [1, 7, 30] as const;
export { MAX_INVITE_LINK_USES } from "./limits";
const DAY_MS = 24 * 60 * 60 * 1000;

/** 32 random bytes, base64url: 256 bits that exist only in the create response. */
export function generateInviteLinkToken(): string {
  return randomBytes(32).toString("base64url");
}

export function hashInviteLinkToken(token: string): string {
  return createHash("sha256").update(token, "utf8").digest("hex");
}

/** Raw tokens are 43 base64url characters; reject anything else before hashing. */
export function isInviteLinkToken(value: string): boolean {
  return /^[A-Za-z0-9_-]{43}$/u.test(value);
}

export function toInviteLink(link: StoredInviteLink): TeamInviteLink {
  return {
    id: link.id,
    role: "member",
    createdAt: link.createdAt.toISOString(),
    createdByUserId: link.createdByUserId,
    expiresAt: link.expiresAt?.toISOString() ?? null,
    maxUses: link.maxUses,
    useCount: link.useCount,
  };
}

export type LinkDependencies = {
  readonly store?: TeamInviteStore;
  readonly stack?: TeamStackApp;
  readonly now?: () => Date;
  readonly seats?: TeamSeatSync;
};

export async function createTeamInviteLink(
  access: TeamAccess,
  input: { readonly expiresInDays: (typeof INVITE_LINK_EXPIRY_DAYS)[number] | null; readonly maxUses: number | null },
  dependencies: LinkDependencies = {},
): Promise<{ link: TeamInviteLink; token: string }> {
  const store = dependencies.store ?? databaseTeamInviteStore;
  const now = (dependencies.now ?? (() => new Date()))();
  const token = generateInviteLinkToken();
  const stored = await store.createLink({
    stackTeamId: access.team.id,
    tokenHash: hashInviteLinkToken(token),
    createdByUserId: access.userId,
    expiresAt: input.expiresInDays === null ? null : new Date(now.getTime() + input.expiresInDays * DAY_MS),
    maxUses: input.maxUses,
  });
  return { link: toInviteLink(stored), token };
}

export async function listTeamInviteLinks(
  access: TeamAccess,
  dependencies: LinkDependencies = {},
): Promise<TeamInviteLink[]> {
  const links = await (dependencies.store ?? databaseTeamInviteStore).listActiveLinks(access.team.id);
  return links.map(toInviteLink);
}

export async function revokeTeamInviteLink(
  access: TeamAccess,
  linkId: string,
  dependencies: LinkDependencies = {},
): Promise<void> {
  const found = await (dependencies.store ?? databaseTeamInviteStore).revokeLink(access.team.id, linkId);
  if (!found) throw new TeamApiError("link_not_found", 404);
}

type ResolvedLink = {
  readonly link: StoredInviteLink;
  readonly team: NonNullable<Awaited<ReturnType<TeamStackApp["getTeam"]>>>;
  readonly alreadyMember: boolean;
  readonly memberCount: number;
};

async function resolveLink(
  userId: string,
  token: string,
  store: TeamInviteStore,
  stack: TeamStackApp,
): Promise<ResolvedLink> {
  if (!isInviteLinkToken(token)) throw new TeamApiError("link_invalid", 410);
  const link = await store.findActiveLinkByTokenHash(hashInviteLinkToken(token));
  if (!link) throw new TeamApiError("link_invalid", 410);
  const team = await withStackDeadline(() => stack.getTeam(link.stackTeamId));
  if (!team) throw new TeamApiError("link_invalid", 410);
  const members = await withStackDeadline(() => team.listUsers());
  return { link, team, alreadyMember: members.some((member) => member.id === userId), memberCount: members.length };
}

function isFull(link: StoredInviteLink): boolean {
  return link.maxUses !== null && link.useCount >= link.maxUses;
}

/** What the join page shows before the user confirms. */
export async function previewTeamInviteLink(
  userId: string,
  token: string,
  dependencies: LinkDependencies = {},
): Promise<{ teamDisplayName: string; alreadyMember: boolean }> {
  // An emailed invitation uses the same join page and token shape.
  const emailed = await previewEmailInvitationToken(userId, token, dependencies);
  if (emailed) return emailed;
  const resolved = await resolveLink(
    userId,
    token,
    dependencies.store ?? databaseTeamInviteStore,
    dependencies.stack ?? defaultTeamStackApp(),
  );
  if (!resolved.alreadyMember && isFull(resolved.link)) throw new TeamApiError("link_invalid", 410);
  return { teamDisplayName: resolved.team.displayName, alreadyMember: resolved.alreadyMember };
}

/**
 * Join through a link. The claim (redemption row plus use-count increment)
 * commits before Stack adds the member and is released if that fails, so a
 * failed join never burns a use. Redeeming twice consumes one use.
 */
export async function redeemTeamInviteLink(
  userId: string,
  token: string,
  dependencies: LinkDependencies = {},
): Promise<{ teamId: string }> {
  const emailed = await acceptEmailInvitationToken(userId, token, dependencies);
  if (emailed) return emailed;
  const store = dependencies.store ?? databaseTeamInviteStore;
  const stack = dependencies.stack ?? defaultTeamStackApp();
  const { link, team, alreadyMember, memberCount } = await resolveLink(userId, token, store, stack);
  if (!alreadyMember) {
    assertSeatsAvailable({ team, occupied: memberCount, adding: 1 });
    const claim = await store.claimLink(link.id, userId);
    if (claim === "unavailable") throw new TeamApiError("link_invalid", 410);
    try {
      await addMember(team, userId);
    } catch (error) {
      if (claim === "claimed") await store.releaseLinkClaim(link.id, userId);
      throw error;
    }
    await (dependencies.seats ?? defaultTeamSeatSync).membershipChanged(team.id);
  }
  await withStackDeadline(async () => {
    const user = await stack.getUser(userId);
    await user?.update({ selectedTeamId: team.id });
  }).catch(() => console.error("team join selection failed", { teamId: team.id }));
  return { teamId: team.id };
}

async function addMember(team: ResolvedLink["team"], userId: string): Promise<void> {
  await withStackDeadline(async () => {
    try {
      await team.addUser(userId);
    } catch (error) {
      if (!isTeamMembershipAlreadyExists(error)) throw error;
    }
  });
}
