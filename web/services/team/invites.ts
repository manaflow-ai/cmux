import { checkRateLimit } from "@vercel/firewall";
import { and, desc, eq, inArray } from "drizzle-orm";
import { Resend } from "resend";
import { z } from "zod";

import { env } from "@/app/env";
import {
  DEFAULT_TEAM_INVITE_FROM_EMAIL,
  buildTeamInviteEmail,
} from "@/app/api/team/invite/team-invite-email";
import { getStackServerApp } from "@/app/lib/stack";
import { cloudDb } from "@/db/client";
import { stripeSubscriptions, teamInviteRoles } from "@/db/schema";
import { ACTIVE_STRIPE_PRO_STATUSES, TEAM_PLAN_ID } from "@/services/billing/pro";
import { resolveBillingTeam } from "@/services/billing/teamResolution";
import { locales } from "@/i18n/routing";
import { captureBillingError } from "@/services/errors";

const emailSchema = z.string().trim().toLowerCase().email().max(320);
const teamNameSchema = z.string().trim().min(1).max(80);
const teamRoleSchema = z.enum(["admin", "member"]).catch("member");
const MAX_TEAM_INVITE_BODY_BYTES = 16 * 1024;
export const TEAM_ADMIN_PERMISSION_ID = "team_admin";
const DEFAULT_TEAM_INVITE_ORIGIN = "https://cmux.com";

export type StackTeamUser = {
  readonly id: string;
  readonly displayName?: string | null;
  readonly primaryEmail?: string | null;
  readonly profileImageUrl?: string | null;
  hasPermission?: (scope: StackTeam, permissionId: string) => Promise<boolean>;
  grantPermission?: (scope: StackTeam, permissionId: string) => Promise<void>;
  revokePermission?: (scope: StackTeam, permissionId: string) => Promise<void>;
  listPermissions?: (scope: StackTeam, options?: { recursive?: boolean }) => Promise<readonly { id: string }[]>;
};

export type StackTeamInvitation = {
  readonly id: string;
  readonly recipientEmail?: string | null;
  readonly expiresAt?: Date | string | null;
  readonly revoke?: () => Promise<void>;
  readonly send?: () => Promise<void>;
  readonly resend?: () => Promise<void>;
};

export type StackTeam = {
  readonly id: string;
  readonly displayName?: string | null;
  readonly name?: string | null;
  update?: (options: { displayName: string }) => Promise<void>;
  listUsers?: () => Promise<readonly StackTeamUser[]>;
  removeUser?: (userId: string) => Promise<void>;
  inviteUser?: (options: { email: string; callbackUrl?: string }) => Promise<StackTeamInvitation | void>;
  sendTeamInvitation?: (options: { email: string; callbackUrl: string }) => Promise<StackTeamInvitation | void>;
  listInvitations?: () => Promise<readonly StackTeamInvitation[]>;
};

export type StackTeamUserLike = {
  readonly id: string;
  readonly displayName?: string | null;
  readonly primaryEmail?: string | null;
  readonly selectedTeam?: unknown;
  readonly listTeams?: () => Promise<readonly unknown[]>;
  readonly createTeam?: (options: { displayName: string }) => Promise<StackTeam>;
  readonly listTeamInvitations?: () => Promise<readonly StackReceivedTeamInvitation[]>;
  hasPermission?: (scope: StackTeam, permissionId: string) => Promise<boolean>;
  grantPermission?: (scope: StackTeam, permissionId: string) => Promise<void>;
  revokePermission?: (scope: StackTeam, permissionId: string) => Promise<void>;
  listPermissions?: (scope: StackTeam, options?: { recursive?: boolean }) => Promise<readonly { id: string }[]>;
};

export type TeamMemberDto = {
  readonly id: string;
  readonly displayName: string | null;
  readonly email: string | null;
  readonly profileImageUrl: string | null;
  readonly role: TeamRole;
};

export type TeamInvitationDto = {
  readonly id: string;
  readonly email: string;
  readonly createdAt: string | null;
  readonly acceptUrl: string | null;
  readonly role: TeamRole;
};

export type TeamSummaryDto = {
  readonly teamId: string;
  readonly teamName: string;
  readonly members: readonly TeamMemberDto[];
  readonly invitations: readonly TeamInvitationDto[];
  readonly seats: number;
  readonly currentUserRole: TeamRole;
  readonly canManageTeam: boolean;
};

export type TeamRole = "admin" | "member";

export type StackReceivedTeamInvitation = {
  readonly id: string;
  readonly teamId: string;
  accept?: () => Promise<void>;
};

export function normalizeInviteEmail(email: unknown): string | null {
  const parsed = emailSchema.safeParse(email);
  return parsed.success ? parsed.data : null;
}

export async function readBoundedJson(request: Request): Promise<unknown> {
  const text = await request.text();
  if (new TextEncoder().encode(text).byteLength > MAX_TEAM_INVITE_BODY_BYTES) {
    throw new TeamInviteHttpError("invalid_request", 413);
  }
  try {
    return text ? JSON.parse(text) : {};
  } catch {
    throw new TeamInviteHttpError("invalid_request", 400);
  }
}

export class TeamInviteHttpError extends Error {
  constructor(
    readonly code: string,
    readonly status: number,
  ) {
    super(code);
    this.name = "TeamInviteHttpError";
  }
}

export async function enforceTeamInviteRateLimit(request: Request): Promise<void> {
  if (process.env.VERCEL !== "1") return;
  const rateLimitId = env.CMUX_FEEDBACK_RATE_LIMIT_ID;
  if (!rateLimitId) return;
  const { error, rateLimited } = await checkRateLimit(rateLimitId, { request });
  if (rateLimited || error === "blocked") {
    throw new TeamInviteHttpError("rate_limited", 429);
  }
  if (error) {
    throw new TeamInviteHttpError("service_unavailable", 503);
  }
}

export async function currentTeamForMember(user: StackTeamUserLike): Promise<StackTeam> {
  const team = await resolveBillingTeam(user);
  if (!team) throw new TeamInviteHttpError("team_not_found", 404);
  const stackTeam = await stackTeamById(user, team.id);
  if (!stackTeam) throw new TeamInviteHttpError("team_not_found", 404);
  await requireTeamMember(stackTeam, user.id);
  return stackTeam;
}

export async function createTeamForUser(user: StackTeamUserLike, displayName: unknown): Promise<StackTeam> {
  const parsed = teamNameSchema.safeParse(displayName);
  if (!parsed.success) throw new TeamInviteHttpError("invalid_request", 400);
  if (!user.createTeam) throw new TeamInviteHttpError("service_unavailable", 503);
  const team = await user.createTeam({ displayName: parsed.data });
  await grantTeamAdmin(user, team);
  return team;
}

export async function updateTeamName(user: StackTeamUserLike, displayName: unknown): Promise<TeamSummaryDto> {
  const parsed = teamNameSchema.safeParse(displayName);
  if (!parsed.success) throw new TeamInviteHttpError("invalid_request", 400);
  const team = await currentTeamForMember(user);
  await requireTeamAdmin(user, team);
  if (!team.update) throw new TeamInviteHttpError("service_unavailable", 503);
  await team.update({ displayName: parsed.data });
  return loadTeamSummary(user);
}

export async function loadTeamSummary(user: StackTeamUserLike): Promise<TeamSummaryDto> {
  const team = await currentTeamForMember(user);
  const [members, invitations, seats] = await Promise.all([
    team.listUsers?.() ?? Promise.resolve([]),
    team.listInvitations?.() ?? Promise.resolve([]),
    latestActiveTeamSeatCount(team.id),
  ]);
  const roles = await roleMapForMembers(team, members);
  const currentUserRole = roleForMember(user.id, roles);
  return {
    teamId: team.id,
    teamName: teamDisplayName(team),
    members: members.map((member) => memberDto(member, roleForMember(member.id, roles))),
    invitations: await Promise.all(invitations.map(async (invitation) => invitationDto(
      invitation,
      null,
      await storedInviteRole(invitation.id),
    ))),
    seats,
    currentUserRole,
    canManageTeam: currentUserRole === "admin",
  };
}

export async function sendTeamInvite(params: {
  user: StackTeamUserLike;
  request: Request;
  email: unknown;
  locale: string;
  role?: unknown;
}): Promise<{ invitation: TeamInvitationDto; acceptUrl: string }> {
  await enforceTeamInviteRateLimit(params.request);
  const email = normalizeInviteEmail(params.email);
  if (!email) throw new TeamInviteHttpError("invalid_email", 400);
  const team = await currentTeamForMember(params.user);
  await requireTeamAdmin(params.user, team);
  const role = teamRoleSchema.parse(params.role);
  const callbackUrl = acceptBaseUrl(params.request, params.locale);
  const invitation = await createStackInvitation(team, email, callbackUrl);
  await recordInviteRole({
    invitationId: invitation.id,
    stackTeamId: team.id,
    role,
    createdByUserId: params.user.id,
  });
  const acceptUrl = acceptUrlForInvitation(params.request, params.locale, invitation);
  await sendBrandedInviteEmail({
    to: email,
    teamName: teamDisplayName(team),
    inviterName: params.user.displayName ?? params.user.primaryEmail ?? null,
    acceptUrl,
    invitationId: invitation.id,
  });
  return { invitation: invitationDto(invitation, acceptUrl, role), acceptUrl };
}

export async function resendTeamInvite(params: {
  user: StackTeamUserLike;
  request: Request;
  invitationId: unknown;
  locale: string;
}): Promise<{ invitation: TeamInvitationDto; acceptUrl: string | null }> {
  await enforceTeamInviteRateLimit(params.request);
  const invitationId = stringId(params.invitationId);
  const team = await currentTeamForMember(params.user);
  await requireTeamAdmin(params.user, team);
  const invitation = await findInvitation(team, invitationId);
  const email = invitationEmail(invitation);
  let resentInvitation = invitation;
  let stackResent = false;
  if (invitation.resend) {
    await invitation.resend();
    stackResent = true;
  } else if (invitation.send) {
    await invitation.send();
    stackResent = true;
  } else if (email && invitation.revoke) {
    const role = await storedInviteRole(invitation.id);
    await invitation.revoke();
    await markInviteRevoked(invitation.id);
    resentInvitation = await createStackInvitation(
      team,
      email,
      acceptBaseUrl(params.request, params.locale),
    );
    await recordInviteRole({
      invitationId: resentInvitation.id,
      stackTeamId: team.id,
      role,
      createdByUserId: params.user.id,
    });
    stackResent = true;
  }
  if (!stackResent) {
    throw new TeamInviteHttpError("email_unavailable", 502);
  }
  const acceptUrl = acceptUrlForInvitation(params.request, params.locale, resentInvitation);
  if (email) {
    await sendBrandedInviteEmail({
      to: email,
      teamName: teamDisplayName(team),
      inviterName: params.user.displayName ?? params.user.primaryEmail ?? null,
      acceptUrl,
      invitationId: resentInvitation.id,
    });
  }
  const role = await storedInviteRole(resentInvitation.id);
  return { invitation: invitationDto(resentInvitation, acceptUrl, role), acceptUrl };
}

export async function revokeTeamInvite(user: StackTeamUserLike, invitationId: unknown): Promise<TeamSummaryDto> {
  const team = await currentTeamForMember(user);
  await requireTeamAdmin(user, team);
  const invitation = await findInvitation(team, stringId(invitationId));
  if (!invitation.revoke) throw new TeamInviteHttpError("service_unavailable", 503);
  await invitation.revoke();
  await markInviteRevoked(invitation.id);
  return loadTeamSummary(user);
}

export async function removeTeamMember(user: StackTeamUserLike, memberId: unknown): Promise<TeamSummaryDto> {
  const targetId = stringId(memberId);
  const team = targetId === user.id
    ? await currentStackTeamForMember(user)
    : await currentTeamForMember(user);
  const members = await requireTeamUsers(team);
  if (members.length <= 1) throw new TeamInviteHttpError("cannot_remove_last_member", 400);
  if (!members.some((member) => member.id === targetId)) {
    throw new TeamInviteHttpError("member_not_found", 404);
  }
  if (targetId !== user.id) {
    await requireTeamAdmin(user, team);
  }
  await guardTargetIsNotLastAdmin(team, members, targetId, "cannot_remove_last_admin");
  if (!team.removeUser) throw new TeamInviteHttpError("service_unavailable", 503);
  await team.removeUser(targetId);
  if (targetId === user.id) return loadTeamSummaryFromTeam(team, user.id);
  return loadTeamSummary(user);
}

export async function updateTeamMemberRole(
  user: StackTeamUserLike,
  memberId: unknown,
  role: unknown,
): Promise<TeamSummaryDto> {
  const targetId = stringId(memberId);
  const parsedRole = teamRoleSchema.parse(role);
  const team = await currentTeamForMember(user);
  await requireTeamAdmin(user, team);
  const members = await requireTeamUsers(team);
  const target = members.find((member) => member.id === targetId);
  if (!target) throw new TeamInviteHttpError("member_not_found", 404);
  if (parsedRole === "admin") {
    await grantTeamAdmin(target, team);
  } else {
    await guardTargetIsNotLastAdmin(team, members, targetId, "cannot_demote_last_admin");
    if (!target.revokePermission) throw new TeamInviteHttpError("service_unavailable", 503);
    await target.revokePermission(team, TEAM_ADMIN_PERMISSION_ID);
  }
  return loadTeamSummary(user);
}

export async function applyAcceptedInvitationRole(params: {
  user: StackTeamUserLike;
  invitationId: string;
  teamId?: string | null;
}): Promise<void> {
  const role = await storedInviteRole(params.invitationId);
  if (role !== "admin") {
    await markInviteAccepted(params.invitationId);
    return;
  }
  const team = await acceptedTeam(params.user, params.teamId);
  await grantTeamAdmin(params.user, team);
  await markInviteAccepted(params.invitationId);
}

export function teamInviteJson(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });
}

export function teamInviteErrorResponse(error: unknown): Response {
  if (error instanceof TeamInviteHttpError) {
    return teamInviteJson({ error: error.code }, error.status);
  }
  captureBillingError(error, { route: "/api/team" });
  return teamInviteJson({ error: "service_unavailable" }, 503);
}

async function createStackInvitation(
  team: StackTeam,
  email: string,
  callbackUrl: string,
): Promise<StackTeamInvitation> {
  const invite = team.sendTeamInvitation ?? team.inviteUser;
  if (!invite) throw new TeamInviteHttpError("service_unavailable", 503);
  const invitation = await invite.call(team, { email, callbackUrl });
  if (isInvitation(invitation)) return invitation;
  const found = (await (team.listInvitations?.() ?? Promise.resolve([])))
    .find((candidate) => invitationEmail(candidate) === email);
  if (found) return found;
  throw new TeamInviteHttpError("service_unavailable", 503);
}

async function sendBrandedInviteEmail(params: {
  to: string;
  teamName: string;
  inviterName: string | null;
  acceptUrl: string;
  invitationId: string;
}): Promise<void> {
  if (!env.RESEND_API_KEY) return;
  const fromEmail = env.CMUX_FEEDBACK_FROM_EMAIL || DEFAULT_TEAM_INVITE_FROM_EMAIL;
  const resend = new Resend(env.RESEND_API_KEY);
  const { error } = await resend.emails.send(
    buildTeamInviteEmail({
      from: `cmux <${fromEmail}>`,
      ...params,
    }),
    { idempotencyKey: `team-invite/${params.invitationId}` },
  );
  if (error) throw new TeamInviteHttpError("email_unavailable", 502);
}

async function stackTeamById(user: StackTeamUserLike, teamId: string): Promise<StackTeam | null> {
  const selected = stackTeamFromUnknown(user.selectedTeam);
  if (selected?.id === teamId) return selected;
  const teams = typeof user.listTeams === "function" ? await user.listTeams() : [];
  return teams.map(stackTeamFromUnknown).find((team): team is StackTeam => !!team && team.id === teamId) ?? null;
}

async function currentStackTeamForMember(user: StackTeamUserLike): Promise<StackTeam> {
  const candidates = [
    stackTeamFromUnknown(user.selectedTeam),
    ...(typeof user.listTeams === "function" ? (await user.listTeams()).map(stackTeamFromUnknown) : []),
  ].filter((team): team is StackTeam => !!team);
  for (const team of candidates) {
    try {
      await requireTeamMember(team, user.id);
      return team;
    } catch (error) {
      if (!isTeamInviteErrorCode(error, "team_not_found")) throw error;
    }
  }
  throw new TeamInviteHttpError("team_not_found", 404);
}

async function loadTeamSummaryFromTeam(team: StackTeam, currentUserId: string): Promise<TeamSummaryDto> {
  const [members, invitations, seats] = await Promise.all([
    team.listUsers?.() ?? Promise.resolve([]),
    team.listInvitations?.() ?? Promise.resolve([]),
    latestActiveTeamSeatCount(team.id),
  ]);
  const roles = await roleMapForMembers(team, members);
  const currentUserRole = roleForMember(currentUserId, roles);
  return {
    teamId: team.id,
    teamName: teamDisplayName(team),
    members: members.map((member) => memberDto(member, roleForMember(member.id, roles))),
    invitations: await Promise.all(invitations.map(async (invitation) => invitationDto(
      invitation,
      null,
      await storedInviteRole(invitation.id),
    ))),
    seats,
    currentUserRole,
    canManageTeam: currentUserRole === "admin",
  };
}

function isTeamInviteErrorCode(error: unknown, code: string): boolean {
  return !!error && typeof error === "object" && (error as { code?: unknown }).code === code;
}

function stackTeamFromUnknown(value: unknown): StackTeam | null {
  if (!value || typeof value !== "object") return null;
  const id = (value as { id?: unknown }).id;
  if (typeof id !== "string" || !id) return null;
  return value as StackTeam;
}

async function requireTeamMember(team: StackTeam, userId: string): Promise<void> {
  const members = await requireTeamUsers(team);
  if (!members.some((member) => member.id === userId)) {
    throw new TeamInviteHttpError("team_not_found", 403);
  }
}

async function requireTeamUsers(team: StackTeam): Promise<readonly StackTeamUser[]> {
  if (!team.listUsers) throw new TeamInviteHttpError("service_unavailable", 503);
  return team.listUsers();
}

async function findInvitation(team: StackTeam, invitationId: string): Promise<StackTeamInvitation> {
  const invitation = (await (team.listInvitations?.() ?? Promise.resolve([])))
    .find((candidate) => candidate.id === invitationId);
  if (!invitation) throw new TeamInviteHttpError("invitation_not_found", 404);
  return invitation;
}

function stringId(value: unknown): string {
  if (typeof value !== "string" || !value.trim()) {
    throw new TeamInviteHttpError("invalid_request", 400);
  }
  return value.trim();
}

function isInvitation(value: unknown): value is StackTeamInvitation {
  return !!value && typeof value === "object" && typeof (value as { id?: unknown }).id === "string";
}

function invitationEmail(invitation: StackTeamInvitation): string | null {
  const email = invitation.recipientEmail;
  return typeof email === "string" && email.trim() ? email.trim().toLowerCase() : null;
}

function invitationDto(invitation: StackTeamInvitation, acceptUrl: string | null, role: TeamRole): TeamInvitationDto {
  return {
    id: invitation.id,
    email: invitationEmail(invitation) ?? "",
    createdAt: dateString(invitation.expiresAt),
    acceptUrl,
    role,
  };
}

function memberDto(member: StackTeamUser, role: TeamRole): TeamMemberDto {
  return {
    id: member.id,
    displayName: member.displayName ?? null,
    email: member.primaryEmail ?? null,
    profileImageUrl: member.profileImageUrl ?? null,
    role,
  };
}

function dateString(value: Date | string | null | undefined): string | null {
  if (!value) return null;
  const date = value instanceof Date ? value : new Date(value);
  return Number.isFinite(date.getTime()) ? date.toISOString() : null;
}

function teamDisplayName(team: StackTeam): string {
  return team.displayName ?? team.name ?? "cmux Team";
}

function safeLocale(locale: string): string {
  // The locale comes from untrusted request JSON and is interpolated into the
  // invite/callback URL path. Without validation a value like "//evil.com" or
  // "..%2f" would resolve to an off-origin host, letting a member send
  // cmux-branded invite emails pointing anywhere. Only allow supported locales.
  return (locales as readonly string[]).includes(locale) ? locale : "en";
}

function acceptBaseUrl(request: Request, locale: string): string {
  const url = new URL(`/${safeLocale(locale)}/dashboard/team/accept`, trustedInviteOrigin(request));
  return url.toString();
}

function acceptUrlForInvitation(request: Request, locale: string, invitation: StackTeamInvitation): string {
  const url = new URL(acceptBaseUrl(request, locale));
  url.searchParams.set("invitation", invitation.id);
  return url.toString();
}

function trustedInviteOrigin(request: Request): string {
  const configured = process.env.CMUX_TEAM_INVITE_ORIGIN?.trim() || process.env.CMUX_APP_ORIGIN?.trim();
  if (configured) return originOrDefault(configured);
  if (process.env.VERCEL_ENV === "production" || process.env.NODE_ENV === "production") {
    return DEFAULT_TEAM_INVITE_ORIGIN;
  }
  return originOrDefault(request.url);
}

function originOrDefault(value: string): string {
  try {
    return new URL(value).origin;
  } catch {
    return DEFAULT_TEAM_INVITE_ORIGIN;
  }
}

async function requireTeamAdmin(user: StackTeamUserLike, team: StackTeam): Promise<void> {
  if (await canManageTeam(user, team)) return;
  throw new TeamInviteHttpError("not_team_admin", 403);
}

async function canManageTeam(user: StackTeamUserLike, team: StackTeam): Promise<boolean> {
  if (await hasTeamAdminPermission(user, team)) return true;
  const members = await requireTeamUsers(team);
  if (!members.some((member) => member.id === user.id)) return false;
  const roles = await roleMapForMembers(team, members);
  const hasAnyAdmin = Array.from(roles.values()).includes("admin");
  if (!hasAnyAdmin) {
    console.warn("team has no admins; applying legacy member-as-admin fallback", { teamId: team.id });
    return true;
  }
  return false;
}

async function roleMapForMembers(
  team: StackTeam,
  members: readonly StackTeamUser[],
): Promise<Map<string, TeamRole>> {
  const roles = new Map(members.map((member) => [member.id, "member" as TeamRole]));
  const app = getStackServerApp() as {
    listTeamMemberPermissions?: (
      teamId: string,
      options?: { recursive?: boolean },
    ) => Promise<readonly { userId: string; permissionId: string }[]>;
  };
  if (app.listTeamMemberPermissions) {
    const grants = await app.listTeamMemberPermissions(team.id, { recursive: true });
    for (const grant of grants) {
      if (grant.permissionId === TEAM_ADMIN_PERMISSION_ID && roles.has(grant.userId)) {
        roles.set(grant.userId, "admin");
      }
    }
    return roles;
  }
  await Promise.all(members.map(async (member) => {
    if (await hasTeamAdminPermission(member, team)) roles.set(member.id, "admin");
  }));
  return roles;
}

function roleForMember(userId: string, roles: ReadonlyMap<string, TeamRole>): TeamRole {
  return roles.get(userId) ?? "member";
}

async function hasTeamAdminPermission(user: StackTeamUserLike, team: StackTeam): Promise<boolean> {
  if (user.hasPermission) return user.hasPermission(team, TEAM_ADMIN_PERMISSION_ID);
  if (user.listPermissions) {
    return (await user.listPermissions(team, { recursive: true }))
      .some((permission) => permission.id === TEAM_ADMIN_PERMISSION_ID);
  }
  return false;
}

async function grantTeamAdmin(user: StackTeamUserLike, team: StackTeam): Promise<void> {
  if (!user.grantPermission) throw new TeamInviteHttpError("service_unavailable", 503);
  await user.grantPermission(team, TEAM_ADMIN_PERMISSION_ID);
}

async function guardTargetIsNotLastAdmin(
  team: StackTeam,
  members: readonly StackTeamUser[],
  targetId: string,
  code: string,
): Promise<void> {
  const roles = await roleMapForMembers(team, members);
  if (roleForMember(targetId, roles) !== "admin") return;
  const adminCount = Array.from(roles.values()).filter((role) => role === "admin").length;
  if (adminCount <= 1) throw new TeamInviteHttpError(code, 400);
}

async function acceptedTeam(user: StackTeamUserLike, teamId: string | null | undefined): Promise<StackTeam> {
  const teams = typeof user.listTeams === "function" ? await user.listTeams() : [];
  const team = teams.map(stackTeamFromUnknown).find((candidate): candidate is StackTeam =>
    !!candidate && (!teamId || candidate.id === teamId)
  );
  if (!team) throw new TeamInviteHttpError("team_not_found", 404);
  return team;
}

async function recordInviteRole(params: {
  invitationId: string;
  stackTeamId: string;
  role: TeamRole;
  createdByUserId: string;
}): Promise<void> {
  await cloudDb()
    .insert(teamInviteRoles)
    .values(params)
    .onConflictDoUpdate({
      target: teamInviteRoles.invitationId,
      set: {
        stackTeamId: params.stackTeamId,
        role: params.role,
        createdByUserId: params.createdByUserId,
        revokedAt: null,
        acceptedAt: null,
      },
    });
}

async function storedInviteRole(invitationId: string): Promise<TeamRole> {
  const [row] = await cloudDb()
    .select({ role: teamInviteRoles.role })
    .from(teamInviteRoles)
    .where(eq(teamInviteRoles.invitationId, invitationId))
    .limit(1);
  return row?.role === "admin" ? "admin" : "member";
}

async function markInviteAccepted(invitationId: string): Promise<void> {
  await cloudDb()
    .update(teamInviteRoles)
    .set({ acceptedAt: new Date() })
    .where(eq(teamInviteRoles.invitationId, invitationId));
}

async function markInviteRevoked(invitationId: string): Promise<void> {
  await cloudDb()
    .update(teamInviteRoles)
    .set({ revokedAt: new Date() })
    .where(eq(teamInviteRoles.invitationId, invitationId));
}

async function latestActiveTeamSeatCount(stackTeamId: string): Promise<number> {
  const rows = await cloudDb()
    .select({ seats: stripeSubscriptions.seats })
    .from(stripeSubscriptions)
    .where(
      and(
        eq(stripeSubscriptions.stackTeamId, stackTeamId),
        eq(stripeSubscriptions.scope, "team"),
        eq(stripeSubscriptions.plan, TEAM_PLAN_ID),
        inArray(stripeSubscriptions.status, ACTIVE_STRIPE_PRO_STATUSES),
      ),
    )
    .orderBy(desc(stripeSubscriptions.currentPeriodEnd), desc(stripeSubscriptions.updatedAt))
    .limit(1);
  return Math.max(0, Number(rows[0]?.seats ?? 0));
}
