import { parseNativeStackTokens } from "../vms/auth";
import { TeamApiError, TeamServiceUnavailableError } from "./errors";
import { createInvitationCodeClient, type InvitationCodeClient, type InvitationCodeFailure } from "./invitationCode";
import { normalizeInviteEmail } from "./invitations";
import { TEAM_ADMIN_PERMISSION } from "./permissions";
import { databaseTeamInviteStore, type TeamInviteStore } from "./repository";
import { defaultTeamSeatSync, type TeamSeatSync } from "./seatSync";
import {
  defaultTeamStackApp,
  withStackDeadline,
  type StackSentInvitation,
  type StackTeam,
  type StackUser,
  type TeamStackApp,
} from "./stack";
import type { TeamRole } from "./types";

export type AcceptDependencies = {
  readonly stack?: TeamStackApp;
  readonly codes?: InvitationCodeClient;
  readonly store?: TeamInviteStore;
  readonly seats?: TeamSeatSync;
};

/**
 * Accept a Stack email invitation for the request's user and apply the role
 * cmux stored for it.
 *
 * 1. Stack's details endpoint names the exact team the code belongs to (and
 *    already refuses a wrong-email user).
 * 2. The team's pending invitations addressed to the user's verified emails
 *    are snapshotted, then the code is used as the caller.
 * 3. The invitation that disappeared is the one this code consumed; its
 *    recipient email keys the stored role.
 *
 * Admin is granted only when exactly one consumed invitation is identified,
 * its stored role is admin, and the user is now a member of that same team.
 * Anything ambiguous leaves the user a member, a downgrade that an admin can
 * fix, never an escalation.
 */
export async function acceptTeamInvitationCode(
  request: Request,
  userId: string,
  code: string,
  dependencies: AcceptDependencies = {},
): Promise<{ teamId: string; role: TeamRole }> {
  const stack = dependencies.stack ?? defaultTeamStackApp();
  const codes = dependencies.codes ?? createInvitationCodeClient();
  const store = dependencies.store ?? databaseTeamInviteStore;
  const seats = dependencies.seats ?? defaultTeamSeatSync;

  const accessToken = await callerAccessToken(request, stack);
  const details = await codes.details(code, accessToken);
  if (!details.ok) throw codeFailure(details.failure);
  const teamId = details.value.teamId;

  const [team, user] = await Promise.all([
    withStackDeadline(() => stack.getTeam(teamId)),
    withStackDeadline(() => stack.getUser(userId)),
  ]);
  if (!team || !user) throw new TeamApiError("invitation_invalid", 410);
  const verifiedEmails = await userVerifiedEmails(user);
  const before = addressedTo(await withStackDeadline(() => team.listInvitations()), verifiedEmails);

  const accepted = await codes.accept(code, accessToken);
  if (!accepted.ok) throw codeFailure(accepted.failure);

  const [members, after] = await Promise.all([
    withStackDeadline(() => team.listUsers()),
    withStackDeadline(() => team.listInvitations()),
  ]);
  if (!members.some((member) => member.id === userId)) {
    throw new TeamServiceUnavailableError("accepted invitation did not add the member");
  }
  await seats.membershipChanged(teamId);
  const consumedEmail = consumedInvitationEmail(before, after);
  const role = await applyStoredRole({ store, team, user, consumedEmail, remaining: after });
  await withStackDeadline(() => user.update({ selectedTeamId: teamId }))
    .catch(() => console.error("team accept selection failed", { teamId }));
  return { teamId, role };
}

async function applyStoredRole(input: {
  readonly store: TeamInviteStore;
  readonly team: StackTeam;
  readonly user: StackUser;
  readonly consumedEmail: string | null;
  readonly remaining: readonly StackSentInvitation[];
}): Promise<TeamRole> {
  if (!input.consumedEmail) return "member";
  const roles = await input.store.inviteRoles(input.team.id, [input.consumedEmail]);
  const role = roles.get(input.consumedEmail) ?? "member";
  if (role === "admin") {
    await withStackDeadline(() => input.user.grantPermission(input.team, TEAM_ADMIN_PERMISSION));
  }
  const stillPending = input.remaining.some(
    (invitation) => invitation.recipientEmail && normalizeInviteEmail(invitation.recipientEmail) === input.consumedEmail,
  );
  if (!stillPending) {
    await input.store.deleteInviteRole(input.team.id, input.consumedEmail).catch(() => {
      console.error("team invite role cleanup failed", { teamId: input.team.id });
    });
  }
  return role;
}

/** Pending invitations addressed to one of the user's verified emails, by id. */
function addressedTo(
  invitations: readonly StackSentInvitation[],
  verifiedEmails: ReadonlySet<string>,
): Map<string, string> {
  const byId = new Map<string, string>();
  for (const invitation of invitations) {
    const email = invitation.recipientEmail ? normalizeInviteEmail(invitation.recipientEmail) : null;
    if (email && verifiedEmails.has(email)) byId.set(invitation.id, email);
  }
  return byId;
}

/** The single recipient email whose invitation the accept consumed, if it is unambiguous. */
export function consumedInvitationEmail(
  before: ReadonlyMap<string, string>,
  after: readonly StackSentInvitation[],
): string | null {
  const remainingIds = new Set(after.map((invitation) => invitation.id));
  const consumed = new Set<string>();
  for (const [id, email] of before) {
    if (!remainingIds.has(id)) consumed.add(email);
  }
  return consumed.size === 1 ? [...consumed][0]! : null;
}

export async function userVerifiedEmails(user: StackUser): Promise<Set<string>> {
  const channels = await withStackDeadline(() => user.listContactChannels());
  const emails = new Set(
    channels.filter((channel) => channel.type === "email" && channel.isVerified)
      .map((channel) => normalizeInviteEmail(channel.value)),
  );
  if (user.primaryEmail && user.primaryEmailVerified) emails.add(normalizeInviteEmail(user.primaryEmail));
  return emails;
}

/** Stack may refresh the session while reading it; use the authoritative token. */
async function callerAccessToken(request: Request, stack: TeamStackApp): Promise<string> {
  const tokenStore = parseNativeStackTokens(request) ?? {
    headers: { get: (name: string): string | null => request.headers.get(name) },
  };
  const auth = await withStackDeadline(() => stack.getAuthJson({ tokenStore }));
  if (!auth.accessToken) throw new TeamApiError("unauthorized", 401);
  return auth.accessToken;
}

function codeFailure(failure: InvitationCodeFailure): Error {
  if (failure === "email_mismatch") return new TeamApiError("email_mismatch", 409);
  if (failure === "invalid") return new TeamApiError("invitation_invalid", 410);
  return new TeamServiceUnavailableError("Stack invitation code request failed");
}
