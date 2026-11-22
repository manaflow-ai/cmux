import { z } from "zod";
import { GET as teamCatalogRoute, PATCH as selectTeamRoute } from "@/app/api/subrouter/teams/route";
import { acceptTeamInvitationCode } from "@/services/teams/accept";
import { createTeamForUser, deleteTeam, updateTeam } from "@/services/teams/admin";
import { loadTeamDetail } from "@/services/teams/detail";
import { inviteTeamMembers, resendTeamInvitation, revokeTeamInvitation } from "@/services/teams/invitations";
import { createTeamInviteLink, previewTeamInviteLink, redeemTeamInviteLink, revokeTeamInviteLink } from "@/services/teams/links";
import { changeMemberRole, removeMember } from "@/services/teams/members";
import { teamInviteAcceptUrl, teamInviteLinkUrl } from "@/services/teams/origin";
import {
  acceptBody,
  createLinkBody,
  createTeamBody,
  inviteBody,
  memberRoleBody,
  updateTeamBody,
} from "@/services/teams/schemas";
import { getStackServerApp } from "@/app/lib/stack";
import { authed, teamAccess, teamRateLimit, teamUser } from "./base";
import { apiKeyRow, apiKeySchema } from "./settings";
import { callRoute } from "./route-call";
import { billing } from "./team-billing";
import {
  invitationSchema,
  inviteLinkSchema,
  teamCatalogSchema,
  teamDetailSchema,
  teamRoleSchema,
} from "./schemas/teams";

const teamId = z.string().trim().min(1).max(200);
const teamInput = z.object({ teamId });
const ok = z.object({ ok: z.literal(true) });
const OK = { ok: true } as const;

/** The viewer's teams, as the dashboard team picker and team pages list them. */
const catalog = authed
  .output(teamCatalogSchema)
  .handler(async ({ context }) =>
    teamCatalogSchema.parse(await callRoute(context, teamCatalogRoute, { method: "GET", path: "/api/subrouter/teams" }))
  );

/** Persist the selected team in Stack Auth. */
const select = authed
  .input(teamInput)
  .output(z.object({ selectedTeamId: z.string() }))
  .handler(async ({ context, input }) =>
    z.object({ selectedTeamId: z.string() }).parse(
      await callRoute(context, selectTeamRoute, { method: "PATCH", path: "/api/subrouter/teams", body: { teamId: input.teamId } }),
    )
  );

const create = teamUser
  .use(teamRateLimit("/api/teams"))
  .input(createTeamBody)
  .output(z.object({ team: z.object({ id: z.string(), displayName: z.string() }) }))
  .handler(async ({ context, input }) => ({ team: await createTeamForUser(context.user.id, input.displayName) }));

const detail = teamUser
  .input(teamInput)
  .use(teamAccess(), (input) => input)
  .output(teamDetailSchema)
  .handler(({ context }) => loadTeamDetail(context.team));

const update = teamUser
  .input(teamInput.extend(updateTeamBody.shape).strict())
  .use(teamAccess({ admin: true, permission: "updateTeam" }), (input) => input)
  .output(z.object({ team: z.object({ id: z.string(), displayName: z.string(), profileImageUrl: z.string().nullable() }) }))
  .handler(async ({ context, input }) => {
    const { teamId: _teamId, ...patch } = input;
    await updateTeam(context.team, patch);
    return {
      team: {
        id: context.team.team.id,
        displayName: patch.displayName ?? context.team.team.displayName,
        profileImageUrl: patch.profileImageUrl !== undefined ? patch.profileImageUrl : context.team.team.profileImageUrl ?? null,
      },
    };
  });

const remove = teamUser
  .input(teamInput)
  .use(teamAccess({ admin: true, permission: "deleteTeam" }), (input) => input)
  .output(ok)
  .handler(async ({ context }) => {
    await deleteTeam(context.team);
    return OK;
  });

const invite = teamUser
  .use(teamRateLimit("/api/teams/[teamId]/invitations"))
  .input(teamInput.extend(inviteBody.shape).strict())
  .use(teamAccess({ admin: true, permission: "inviteMembers" }), (input) => input)
  .output(z.object({
    invitations: z.array(invitationSchema),
    failed: z.array(z.object({ email: z.string(), code: z.enum(["already_member", "invite_failed"]) })),
  }))
  .handler(({ context, input }) =>
    inviteTeamMembers(context.team, {
      emails: input.emails,
      role: input.role,
      acceptUrl: (token) => teamInviteLinkUrl(context.request, token),
    })
  );

const invitationInput = teamInput.extend({ invitationId: z.uuid() });

const resendInvitation = teamUser
  .use(teamRateLimit("/api/teams/[teamId]/invitations/[invitationId]/resend"))
  .input(invitationInput)
  .use(teamAccess({ admin: true, permission: "inviteMembers" }), (input) => input)
  .output(z.object({ invitation: invitationSchema }))
  .handler(async ({ context, input }) => ({
    invitation: await resendTeamInvitation(context.team, input.invitationId, (token) => teamInviteLinkUrl(context.request, token)),
  }));

const revokeInvitation = teamUser
  .input(invitationInput)
  .use(teamAccess({ admin: true, permission: "inviteMembers" }), (input) => input)
  .output(ok)
  .handler(async ({ context, input }) => {
    await revokeTeamInvitation(context.team, input.invitationId);
    return OK;
  });

const createLink = teamUser
  .use(teamRateLimit("/api/teams/[teamId]/links"))
  .input(teamInput.extend(createLinkBody.shape).strict())
  .use(teamAccess({ admin: true, permission: "inviteMembers" }), (input) => input)
  .output(z.object({ link: inviteLinkSchema, url: z.string() }))
  .handler(async ({ context, input }) => {
    const { link, token } = await createTeamInviteLink(context.team, {
      expiresInDays: input.expiresInDays,
      maxUses: input.maxUses,
    });
    return { link, url: teamInviteLinkUrl(context.request, token) };
  });

const revokeLink = teamUser
  .input(teamInput.extend({ linkId: z.uuid() }))
  .use(teamAccess({ admin: true }), (input) => input)
  .output(ok)
  .handler(async ({ context, input }) => {
    await revokeTeamInviteLink(context.team, input.linkId);
    return OK;
  });

const memberInput = teamInput.extend({ userId: z.uuid() });

const changeRole = teamUser
  .input(memberInput.extend(memberRoleBody.shape).strict())
  .use(teamAccess({ admin: true }), (input) => input)
  .output(z.object({ member: z.object({ userId: z.string(), role: teamRoleSchema }) }))
  .handler(async ({ context, input }) => ({ member: await changeMemberRole(context.team, input.userId, input.role) }));

/** Remove a member (admin), or leave the team (self). */
const removeMemberProcedure = teamUser
  .input(memberInput)
  .use(teamAccess(), (input) => input)
  .output(ok)
  .handler(async ({ context, input }) => {
    await removeMember(context.team, input.userId);
    return OK;
  });

const tokenInput = z.object({ token: z.string().min(1).max(512) });

const joinInfo = teamUser
  .use(teamRateLimit("/api/teams/join/[token]"))
  .input(tokenInput)
  .output(z.object({ teamDisplayName: z.string(), alreadyMember: z.boolean() }))
  .handler(({ context, input }) => previewTeamInviteLink(context.user.id, input.token));

const join = teamUser
  .use(teamRateLimit("/api/teams/join/[token]"))
  .input(tokenInput)
  .output(z.object({ teamId: z.string() }))
  .handler(({ context, input }) => redeemTeamInviteLink(context.user.id, input.token));

const accept = teamUser
  .use(teamRateLimit("/api/teams/accept"))
  .input(acceptBody)
  .output(z.object({ teamId: z.string() }))
  .handler(async ({ context, input }) => {
    const { teamId: acceptedTeamId } = await acceptTeamInvitationCode(context.request, context.user.id, input.code);
    return { teamId: acceptedTeamId };
  });

/**
 * The team's API keys for a viewer with `$manage_api_keys`. A project without
 * team API keys answers `enabled: false`; that is a setting, not a failure.
 * Creating and revoking keys stays on the client SDK under the viewer's session.
 */
const apiKeys = teamUser
  .input(teamInput)
  .use(teamAccess({ permission: "manageApiKeys" }), (input) => input)
  .output(z.object({ enabled: z.boolean(), keys: z.array(apiKeySchema) }))
  .handler(async ({ context }) => {
    const app = getStackServerApp();
    const project = await app.getProject();
    if (!project.config.allowTeamApiKeys) return { enabled: false, keys: [] };
    const team = await app.getTeam(context.team.team.id);
    if (!team) return { enabled: true, keys: [] };
    return { enabled: true, keys: (await team.listApiKeys()).map(apiKeyRow) };
  });

export const teamsRouter = {
  catalog,
  select,
  create,
  detail,
  update,
  remove,
  invite,
  resendInvitation,
  revokeInvitation,
  createLink,
  revokeLink,
  changeRole,
  removeMember: removeMemberProcedure,
  joinInfo,
  join,
  accept,
  billing,
  apiKeys,
};
