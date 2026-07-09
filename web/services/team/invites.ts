import { checkRateLimit } from "@vercel/firewall";
import { and, desc, eq, inArray } from "drizzle-orm";
import { Resend } from "resend";
import { z } from "zod";

import { env } from "@/app/env";
import {
  DEFAULT_TEAM_INVITE_FROM_EMAIL,
  buildTeamInviteEmail,
} from "@/app/api/team/invite/team-invite-email";
import { cloudDb } from "@/db/client";
import { stripeSubscriptions } from "@/db/schema";
import { ACTIVE_STRIPE_PRO_STATUSES, TEAM_PLAN_ID } from "@/services/billing/pro";
import { resolveBillingTeam } from "@/services/billing/teamResolution";
import { captureBillingError } from "@/services/errors";

const emailSchema = z.string().trim().toLowerCase().email().max(320);
const teamNameSchema = z.string().trim().min(1).max(80);
const MAX_TEAM_INVITE_BODY_BYTES = 16 * 1024;

export type StackTeamUser = {
  readonly id: string;
  readonly displayName?: string | null;
  readonly primaryEmail?: string | null;
  readonly profileImageUrl?: string | null;
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
};

export type TeamMemberDto = {
  readonly id: string;
  readonly displayName: string | null;
  readonly email: string | null;
  readonly profileImageUrl: string | null;
};

export type TeamInvitationDto = {
  readonly id: string;
  readonly email: string;
  readonly createdAt: string | null;
  readonly acceptUrl: string | null;
};

export type TeamSummaryDto = {
  readonly teamId: string;
  readonly teamName: string;
  readonly members: readonly TeamMemberDto[];
  readonly invitations: readonly TeamInvitationDto[];
  readonly seats: number;
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
  return user.createTeam({ displayName: parsed.data });
}

export async function updateTeamName(user: StackTeamUserLike, displayName: unknown): Promise<TeamSummaryDto> {
  const parsed = teamNameSchema.safeParse(displayName);
  if (!parsed.success) throw new TeamInviteHttpError("invalid_request", 400);
  const team = await currentTeamForMember(user);
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
  return {
    teamId: team.id,
    teamName: teamDisplayName(team),
    members: members.map(memberDto),
    invitations: invitations.map((invitation) => invitationDto(invitation, null)),
    seats,
  };
}

export async function sendTeamInvite(params: {
  user: StackTeamUserLike;
  request: Request;
  email: unknown;
  locale: string;
}): Promise<{ invitation: TeamInvitationDto; acceptUrl: string }> {
  await enforceTeamInviteRateLimit(params.request);
  const email = normalizeInviteEmail(params.email);
  if (!email) throw new TeamInviteHttpError("invalid_email", 400);
  const team = await currentTeamForMember(params.user);
  const callbackUrl = acceptBaseUrl(params.request, params.locale);
  const invitation = await createStackInvitation(team, email, callbackUrl);
  const acceptUrl = acceptUrlForInvitation(params.request, params.locale, invitation);
  await sendBrandedInviteEmail({
    to: email,
    teamName: teamDisplayName(team),
    inviterName: params.user.displayName ?? params.user.primaryEmail ?? null,
    acceptUrl,
    invitationId: invitation.id,
  });
  return { invitation: invitationDto(invitation, acceptUrl), acceptUrl };
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
  const invitation = await findInvitation(team, invitationId);
  const email = invitationEmail(invitation);
  let resentInvitation = invitation;
  if (invitation.resend) {
    await invitation.resend();
  } else if (invitation.send) {
    await invitation.send();
  } else if (email && invitation.revoke) {
    await invitation.revoke();
    resentInvitation = await createStackInvitation(
      team,
      email,
      acceptBaseUrl(params.request, params.locale),
    );
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
  return { invitation: invitationDto(resentInvitation, acceptUrl), acceptUrl };
}

export async function revokeTeamInvite(user: StackTeamUserLike, invitationId: unknown): Promise<TeamSummaryDto> {
  const team = await currentTeamForMember(user);
  const invitation = await findInvitation(team, stringId(invitationId));
  if (!invitation.revoke) throw new TeamInviteHttpError("service_unavailable", 503);
  await invitation.revoke();
  return loadTeamSummary(user);
}

export async function removeTeamMember(user: StackTeamUserLike, memberId: unknown): Promise<TeamSummaryDto> {
  const targetId = stringId(memberId);
  if (targetId === user.id) throw new TeamInviteHttpError("cannot_remove_self", 400);
  const team = await currentTeamForMember(user);
  const members = await requireTeamUsers(team);
  if (members.length <= 1) throw new TeamInviteHttpError("cannot_remove_last_member", 400);
  if (!members.some((member) => member.id === targetId)) {
    throw new TeamInviteHttpError("member_not_found", 404);
  }
  if (!team.removeUser) throw new TeamInviteHttpError("service_unavailable", 503);
  await team.removeUser(targetId);
  return loadTeamSummary(user);
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

function invitationDto(invitation: StackTeamInvitation, acceptUrl: string | null): TeamInvitationDto {
  return {
    id: invitation.id,
    email: invitationEmail(invitation) ?? "",
    createdAt: dateString(invitation.expiresAt),
    acceptUrl,
  };
}

function memberDto(member: StackTeamUser): TeamMemberDto {
  return {
    id: member.id,
    displayName: member.displayName ?? null,
    email: member.primaryEmail ?? null,
    profileImageUrl: member.profileImageUrl ?? null,
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

function acceptBaseUrl(request: Request, locale: string): string {
  const url = new URL(`/${locale}/dashboard/team/accept`, request.url);
  return url.toString();
}

function acceptUrlForInvitation(request: Request, locale: string, invitation: StackTeamInvitation): string {
  const url = new URL(acceptBaseUrl(request, locale));
  url.searchParams.set("invitation", invitation.id);
  return url.toString();
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
