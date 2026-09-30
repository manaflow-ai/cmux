"use client";

import {
  type QueryClient,
  type UseMutationOptions,
  useMutation,
  useQueryClient,
} from "@tanstack/react-query";
import type { TeamDetail, TeamRole } from "@/services/teams/types";
import { dashboardRefusal } from "../lib/refusal";
import { dashboardClient, rpc } from "../lib/rpc";

// Wire types of the Team API contract (docs/team-settings-and-invites.md),
// the same types the procedures' output schemas satisfy.
export type {
  TeamBillingSummary,
  TeamDetail,
  TeamInvitation,
  TeamInviteLink,
  TeamMember,
  TeamRole,
  TeamViewerPermissions,
} from "@/services/teams/types";
export type { TeamCatalog, TeamCatalogEntry } from "@/orpc/server/dashboard/schemas/teams";

type TeamsClient = typeof dashboardClient.teams;
export type InviteResult = Awaited<ReturnType<TeamsClient["invite"]>>;
export type CreatedInviteLink = Awaited<ReturnType<TeamsClient["createLink"]>>;
export type JoinLinkInfo = Awaited<ReturnType<TeamsClient["joinInfo"]>>;

const REQUEST_TIMEOUT_MS = 15_000;
const timeout = { context: { timeoutMs: REQUEST_TIMEOUT_MS } } as const;

/** The team error code of a declared refusal (`last_admin`, ...), else `"unknown"`. */
export function teamErrorCode(error: unknown): string {
  return dashboardRefusal(error)?.reason ?? "unknown";
}

/** The server's message for a declared refusal, when it sent one. */
export function teamErrorMessage(error: unknown): string | undefined {
  return dashboardRefusal(error)?.message;
}

/** Positional wrappers over the typed team procedures, as the team screens call them. */
export const teamApi = {
  create: (displayName: string) => dashboardClient.teams.create({ displayName }, timeout),
  update: (teamId: string, patch: { displayName?: string; profileImageUrl?: string | null }) =>
    dashboardClient.teams.update({ teamId, ...patch }, timeout),
  remove: (teamId: string) => dashboardClient.teams.remove({ teamId }, timeout),
  invite: (teamId: string, emails: readonly string[], role: TeamRole) =>
    dashboardClient.teams.invite({ teamId, emails: [...emails], role }, timeout),
  resendInvitation: (teamId: string, invitationId: string) =>
    dashboardClient.teams.resendInvitation({ teamId, invitationId }, timeout),
  revokeInvitation: (teamId: string, invitationId: string) =>
    dashboardClient.teams.revokeInvitation({ teamId, invitationId }, timeout),
  createLink: (teamId: string, input: { expiresInDays: 1 | 7 | 30 | null; maxUses: number | null }) =>
    dashboardClient.teams.createLink({ teamId, ...input }, timeout),
  revokeLink: (teamId: string, linkId: string) => dashboardClient.teams.revokeLink({ teamId, linkId }, timeout),
  changeRole: (teamId: string, userId: string, role: TeamRole) =>
    dashboardClient.teams.changeRole({ teamId, userId, role }, timeout),
  removeMember: (teamId: string, userId: string) => dashboardClient.teams.removeMember({ teamId, userId }, timeout),
  joinInfo: (token: string, signal?: AbortSignal) => dashboardClient.teams.joinInfo({ token }, { signal, ...timeout }),
  join: (token: string) => dashboardClient.teams.join({ token }, timeout),
  accept: (code: string) => dashboardClient.teams.accept({ code }, timeout),
};

export const teamQueryKeys = {
  catalog: rpc.teams.catalog.queryKey(),
  detail: (teamId: string) => rpc.teams.detail.queryKey({ input: { teamId } }),
};

/** The viewer's teams and the server-selected one. */
export const teamCatalogQuery = rpc.teams.catalog.queryOptions({ context: timeout.context });

/** `team_not_found` (403) and 404 mean "not a member". */
export function isNotMemberError(error: unknown): boolean {
  const status = dashboardRefusal(error)?.status;
  return status === 403 || status === 404;
}

/** Members, invitations, links, billing summary, and viewer permissions. */
export function teamDetailQuery(teamId: string) {
  return rpc.teams.detail.queryOptions({
    input: { teamId },
    context: timeout.context,
    // 4xx refusals mean "not a member"; retrying cannot change that.
    retry: (failureCount, error) => {
      const status = dashboardRefusal(error)?.status;
      return !(status !== undefined && status >= 400 && status < 500) && failureCount < 2;
    },
  });
}

type DetailContext = { readonly previous: TeamDetail | undefined };

/**
 * Mutation options that apply `optimistic` to the cached team detail before
 * the request, restore the snapshot on failure, and refetch afterwards.
 * Exported as a factory so tests can drive it with a bare QueryClient.
 */
/**
 * Mutations that write to one team share a scope, so TanStack Query runs
 * them one at a time and each waits for the previous `onSettled` (its detail
 * refetch). Deleting or leaving a team therefore starts only after earlier
 * edits settled, and no late refetch asks for a team that is gone.
 */
export function teamMutationScope(teamId: string) {
  return { id: `team:${teamId}` } as const;
}

export function optimisticDetailMutation<Variables, Result>(
  queryClient: QueryClient,
  teamId: string,
  mutationFn: (variables: Variables) => Promise<Result>,
  optimistic: (detail: TeamDetail, variables: Variables) => TeamDetail,
): UseMutationOptions<Result, unknown, Variables, DetailContext> {
  const key = teamQueryKeys.detail(teamId);
  return {
    mutationFn,
    scope: teamMutationScope(teamId),
    onMutate: async (variables) => {
      await queryClient.cancelQueries({ queryKey: key });
      const previous = queryClient.getQueryData<TeamDetail>(key);
      if (previous) queryClient.setQueryData<TeamDetail>(key, optimistic(previous, variables));
      return { previous };
    },
    onError: (_error, _variables, context) => {
      if (context?.previous) queryClient.setQueryData(key, context.previous);
    },
    onSettled: () => queryClient.invalidateQueries({ queryKey: key }),
  };
}

export function revokeInvitationMutation(queryClient: QueryClient, teamId: string) {
  return optimisticDetailMutation(
    queryClient,
    teamId,
    (invitationId: string) => teamApi.revokeInvitation(teamId, invitationId),
    (detail, invitationId) => ({
      ...detail,
      invitations: detail.invitations.filter((invitation) => invitation.id !== invitationId),
    }),
  );
}

export function revokeLinkMutation(queryClient: QueryClient, teamId: string) {
  return optimisticDetailMutation(
    queryClient,
    teamId,
    (linkId: string) => teamApi.revokeLink(teamId, linkId),
    (detail, linkId) => ({ ...detail, links: detail.links.filter((link) => link.id !== linkId) }),
  );
}

export function changeRoleMutation(queryClient: QueryClient, teamId: string) {
  return optimisticDetailMutation(
    queryClient,
    teamId,
    ({ userId, role }: { userId: string; role: TeamRole }) => teamApi.changeRole(teamId, userId, role),
    (detail, { userId, role }) => ({
      ...detail,
      members: detail.members.map((member) => (member.userId === userId ? { ...member, role } : member)),
    }),
  );
}

export function removeMemberMutation(queryClient: QueryClient, teamId: string) {
  return optimisticDetailMutation(
    queryClient,
    teamId,
    (userId: string) => teamApi.removeMember(teamId, userId),
    (detail, userId) => ({
      ...detail,
      members: detail.members.filter((member) => member.userId !== userId),
    }),
  );
}

export function resendInvitationMutation(queryClient: QueryClient, teamId: string) {
  return optimisticDetailMutation(
    queryClient,
    teamId,
    (invitationId: string) => teamApi.resendInvitation(teamId, invitationId),
    // The new expiry is only known from the response; the refetch picks it up.
    (detail) => detail,
  );
}

export function updateTeamMutation(queryClient: QueryClient, teamId: string) {
  return {
    ...optimisticDetailMutation(
      queryClient,
      teamId,
      (patch: { displayName?: string; profileImageUrl?: string | null }) => teamApi.update(teamId, patch),
      (detail, patch) => ({ ...detail, team: { ...detail.team, ...patch } }),
    ),
    onSettled: async () => {
      await Promise.all([
        queryClient.invalidateQueries({ queryKey: teamQueryKeys.detail(teamId) }),
        queryClient.invalidateQueries({ queryKey: teamQueryKeys.catalog }),
      ]);
    },
  };
}

export function useRevokeInvitation(teamId: string) {
  return useMutation(revokeInvitationMutation(useQueryClient(), teamId));
}

export function useResendInvitation(teamId: string) {
  return useMutation(resendInvitationMutation(useQueryClient(), teamId));
}

export function useRevokeLink(teamId: string) {
  return useMutation(revokeLinkMutation(useQueryClient(), teamId));
}

export function useChangeRole(teamId: string) {
  return useMutation(changeRoleMutation(useQueryClient(), teamId));
}

export function useRemoveMember(teamId: string) {
  return useMutation(removeMemberMutation(useQueryClient(), teamId));
}

export function useUpdateTeam(teamId: string) {
  return useMutation(updateTeamMutation(useQueryClient(), teamId));
}

export function useInviteMembers(teamId: string) {
  const queryClient = useQueryClient();
  return useMutation({
    scope: teamMutationScope(teamId),
    mutationFn: ({ emails, role }: { emails: readonly string[]; role: TeamRole }) =>
      teamApi.invite(teamId, emails, role),
    onSuccess: (result) => {
      queryClient.setQueryData<TeamDetail>(teamQueryKeys.detail(teamId), (detail) =>
        detail
          ? {
            ...detail,
            invitations: [
              ...detail.invitations.filter(
                (existing) => !result.invitations.some((added) => added.id === existing.id),
              ),
              ...result.invitations,
            ],
          }
          : detail,
      );
    },
    onSettled: () => queryClient.invalidateQueries({ queryKey: teamQueryKeys.detail(teamId) }),
  });
}

export function useCreateLink(teamId: string) {
  const queryClient = useQueryClient();
  return useMutation({
    scope: teamMutationScope(teamId),
    mutationFn: (input: { expiresInDays: 1 | 7 | 30 | null; maxUses: number | null }) =>
      teamApi.createLink(teamId, input),
    onSuccess: ({ link }) => {
      queryClient.setQueryData<TeamDetail>(teamQueryKeys.detail(teamId), (detail) =>
        detail ? { ...detail, links: [...detail.links, link] } : detail,
      );
    },
  });
}

/**
 * The caller leaves the team route first, then calls `forgetTeam`: dropping
 * the detail while the team shell is mounted would refetch it and show
 * "not found" for a moment.
 */
export function useDeleteTeam(teamId: string) {
  return useMutation({ scope: teamMutationScope(teamId), mutationFn: () => teamApi.remove(teamId) });
}

/**
 * After leaving or deleting a team: drop its detail and refresh the team
 * scope. The team screen may still be mounted while navigation commits, and
 * removing an observed query makes its observer fetch it again, which asks
 * the server for a team that no longer exists. So the detail is cancelled
 * now and removed when its last observer unmounts.
 */
export async function forgetTeam(queryClient: QueryClient, teamId: string): Promise<void> {
  const queryKey = teamQueryKeys.detail(teamId);
  await queryClient.cancelQueries({ queryKey });
  removeWhenUnobserved(queryClient, queryKey);
  await invalidateTeamScope(queryClient);
}

function removeWhenUnobserved(queryClient: QueryClient, queryKey: readonly unknown[]): void {
  const cache = queryClient.getQueryCache();
  const query = cache.find({ queryKey, exact: true });
  if (!query) return;
  if (query.getObserversCount() === 0) {
    cache.remove(query);
    return;
  }
  const unsubscribe = cache.subscribe((event) => {
    if (event.query !== query || event.type !== "observerRemoved") return;
    if (query.getObserversCount() > 0) return;
    unsubscribe();
    cache.remove(query);
  });
}

export function useCreateTeam() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (displayName: string) => teamApi.create(displayName),
    onSuccess: () => invalidateTeamScope(queryClient),
  });
}

/**
 * Creating or joining a team selects it on the server. Refresh this page's
 * catalog and the dashboard-wide team scope so both show the new selection.
 */
export async function invalidateTeamScope(queryClient: QueryClient): Promise<void> {
  await Promise.all([
    queryClient.invalidateQueries({ queryKey: teamQueryKeys.catalog }),
    queryClient.invalidateQueries({ queryKey: ["dashboard-team-catalog"] }),
  ]);
}

/** The viewer is the only admin, so leaving or demoting would orphan the team. */
export function isLastAdmin(detail: TeamDetail): boolean {
  if (detail.viewer.role !== "admin") return false;
  return detail.members.filter((member) => member.role === "admin").length <= 1;
}
