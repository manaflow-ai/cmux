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
 *    recipient email keys the stored role, and its id must be the invitation
 *    that role was sent with (members can send Stack invitations too).
 *
 * Admin is granted only when exactly one consumed invitation is identified,
 * the role stored for it is admin and bound to that invitation's id, and the
 * user is now a member of that same team.
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
  const consumed = consumedInvitation(before, after);
  const role = await applyStoredRole({ store, team, user, consumed, remaining: after });
  await withStackDeadline(() => user.update({ selectedTeamId: teamId }))
    .catch(() => console.error("team accept selection failed", { teamId }));
  return { teamId, role };
}

async function applyStoredRole(input: {
  readonly store: TeamInviteStore;
  readonly team: StackTeam;
  readonly user: StackUser;
  readonly consumed: ConsumedInvitation | null;
  readonly remaining: readonly StackSentInvitation[];
}): Promise<TeamRole> {
  if (!input.consumed) return "member";
  const { id: consumedId, email: consumedEmail } = input.consumed;
  const stored = (await input.store.inviteRoles(input.team.id, [consumedEmail])).get(consumedEmail);
  const role: TeamRole = stored?.stackInvitationId === consumedId ? stored.role : "member";
  if (role === "admin") {
    await withStackDeadline(() => input.user.grantPermission(input.team, TEAM_ADMIN_PERMISSION));
  }
  const stillPending = input.remaining.some(
    (invitation) => invitation.recipientEmail && normalizeInviteEmail(invitation.recipientEmail) === consumedEmail,
  );
  if (!stillPending) {
    await input.store.deleteInviteRole(input.team.id, consumedEmail).catch(() => {
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

type ConsumedInvitation = { readonly id: string; readonly email: string };

/** The single invitation the accept consumed, if it is unambiguous. */
export function consumedInvitation(
  before: ReadonlyMap<string, string>,
  after: readonly StackSentInvitation[],
): ConsumedInvitation | null {
  const remainingIds = new Set(after.map((invitation) => invitation.id));
  const consumed = [...before].filter(([id]) => !remainingIds.has(id));
  if (consumed.length !== 1) return null;
  const [id, email] = consumed[0]!;
  return { id, email };
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
