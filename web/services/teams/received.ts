// Invitations addressed to the signed-in user, and accepting or declining
// them. The verified email is the proof, so no token is needed once signed
// in; the emailed link goes through the same path with the token as proof.
import { userVerifiedEmails } from "./accept";
import { TeamApiError } from "./errors";
import { hashInviteLinkToken, isInviteLinkToken } from "./links";
import { TEAM_ADMIN_PERMISSION } from "./permissions";
import { databaseTeamInviteStore, type StoredEmailInvitation, type TeamInviteStore } from "./repository";
import { assertSeatsAvailable } from "./seats";
import { defaultTeamSeatSync, type TeamSeatSync } from "./seatSync";
import {
  defaultTeamStackApp,
  isTeamMembershipAlreadyExists,
  withStackDeadline,
  type StackTeam,
  type StackUser,
  type TeamStackApp,
} from "./stack";
import type { ReceivedTeamInvitation, TeamRole } from "./types";

export type ReceivedDependencies = {
  readonly store?: TeamInviteStore;
  readonly stack?: TeamStackApp;
  readonly seats?: TeamSeatSync;
};

async function inviterName(team: StackTeam, invitedByUserId: string): Promise<string | null> {
  const members = await withStackDeadline(() => team.listUsers()).catch(() => []);
  const inviter = members.find((member) => member.id === invitedByUserId);
  return inviter?.teamProfile?.displayName || inviter?.displayName || inviter?.primaryEmail || null;
}

/** Pending invitations for any of the user's verified emails, newest first. */
export async function listReceivedInvitations(
  userId: string,
  dependencies: ReceivedDependencies = {},
): Promise<ReceivedTeamInvitation[]> {
  const store = dependencies.store ?? databaseTeamInviteStore;
  const stack = dependencies.stack ?? defaultTeamStackApp();
  const user = await withStackDeadline(() => stack.getUser(userId));
  if (!user) throw new TeamApiError("unauthorized", 401);
  const emails = [...await userVerifiedEmails(user)];
  const rows = await store.listPendingEmailInvitationsForEmails(emails);
  const result: ReceivedTeamInvitation[] = [];
  for (const row of rows) {
    const team = await withStackDeadline(() => stack.getTeam(row.stackTeamId)).catch(() => null);
    // A deleted team's invitation cannot be accepted; leave it out.
    if (!team) continue;
    result.push({
      id: row.id,
      teamId: team.id,
      teamName: team.displayName,
      email: row.email,
      role: row.role,
      invitedBy: await inviterName(team, row.invitedByUserId),
      expiresAt: row.expiresAt.toISOString(),
    });
  }
  return result;
}

type Resolved = { readonly invitation: StoredEmailInvitation; readonly team: StackTeam; readonly user: StackUser };

async function resolveForUser(
  userId: string,
  invitation: StoredEmailInvitation | null,
  store: TeamInviteStore,
  stack: TeamStackApp,
): Promise<Resolved> {
  if (!invitation || invitation.acceptedAt || invitation.declinedAt || invitation.revokedAt || invitation.expiresAt <= new Date()) {
    throw new TeamApiError("invitation_invalid", 410);
  }
  const [team, user] = await Promise.all([
    withStackDeadline(() => stack.getTeam(invitation.stackTeamId)),
    withStackDeadline(() => stack.getUser(userId)),
  ]);
  if (!team) throw new TeamApiError("invitation_invalid", 410);
  if (!user) throw new TeamApiError("unauthorized", 401);
  const verified = await userVerifiedEmails(user);
  if (!verified.has(invitation.email)) throw new TeamApiError("email_mismatch", 409);
  void store;
  return { invitation, team, user };
}

/**
 * Join the team. Membership is written before the row is marked accepted,
 * so a Stack failure leaves the invitation usable; a row that another
 * request accepted first still ends as a member, never as an error.
 */
async function join(resolved: Resolved, store: TeamInviteStore, seats: TeamSeatSync): Promise<{ teamId: string; role: TeamRole }> {
  const { invitation, team, user } = resolved;
  const members = await withStackDeadline(() => team.listUsers());
  if (!members.some((member) => member.id === user.id)) {
    assertSeatsAvailable({ team, occupied: members.length, adding: 1 });
    await withStackDeadline(async () => {
      try {
        await team.addUser(user.id);
      } catch (error) {
        if (!isTeamMembershipAlreadyExists(error)) throw error;
      }
    });
    await seats.membershipChanged(team.id);
  }
  if (invitation.role === "admin") {
    await withStackDeadline(() => user.grantPermission(team, TEAM_ADMIN_PERMISSION));
  }
  await store.acceptEmailInvitation(invitation.id, user.id);
  await withStackDeadline(() => user.update({ selectedTeamId: team.id }))
    .catch(() => console.error("team accept selection failed", { teamId: team.id }));
  return { teamId: team.id, role: invitation.role };
}

/** Accept by id for a signed-in user whose verified email matches. */
export async function acceptReceivedInvitation(
  userId: string,
  invitationId: string,
  dependencies: ReceivedDependencies = {},
): Promise<{ teamId: string; role: TeamRole }> {
  const store = dependencies.store ?? databaseTeamInviteStore;
  const stack = dependencies.stack ?? defaultTeamStackApp();
  const resolved = await resolveForUser(userId, await store.findEmailInvitation(invitationId), store, stack);
  return join(resolved, store, dependencies.seats ?? defaultTeamSeatSync);
}

export async function declineReceivedInvitation(
  userId: string,
  invitationId: string,
  dependencies: ReceivedDependencies = {},
): Promise<void> {
  const store = dependencies.store ?? databaseTeamInviteStore;
  const stack = dependencies.stack ?? defaultTeamStackApp();
  const resolved = await resolveForUser(userId, await store.findEmailInvitation(invitationId), store, stack);
  await store.declineEmailInvitation(resolved.invitation.id);
}

/** The emailed link: the token names the row, the signed-in email must still match. */
export async function previewEmailInvitationToken(
  userId: string,
  token: string,
  dependencies: ReceivedDependencies = {},
): Promise<{ teamDisplayName: string; alreadyMember: boolean } | null> {
  const store = dependencies.store ?? databaseTeamInviteStore;
  const stack = dependencies.stack ?? defaultTeamStackApp();
  if (!isInviteLinkToken(token)) return null;
  const invitation = await store.findPendingEmailInvitationByTokenHash(hashInviteLinkToken(token));
  if (!invitation) return null;
  const resolved = await resolveForUser(userId, invitation, store, stack);
  const members = await withStackDeadline(() => resolved.team.listUsers());
  return { teamDisplayName: resolved.team.displayName, alreadyMember: members.some((member) => member.id === userId) };
}

export async function acceptEmailInvitationToken(
  userId: string,
  token: string,
  dependencies: ReceivedDependencies = {},
): Promise<{ teamId: string } | null> {
  const store = dependencies.store ?? databaseTeamInviteStore;
  const stack = dependencies.stack ?? defaultTeamStackApp();
  if (!isInviteLinkToken(token)) return null;
  const invitation = await store.findPendingEmailInvitationByTokenHash(hashInviteLinkToken(token));
  if (!invitation) return null;
  const resolved = await resolveForUser(userId, invitation, store, stack);
  const { teamId } = await join(resolved, store, dependencies.seats ?? defaultTeamSeatSync);
  return { teamId };
}
