"use client";

import {
  type QueryClient,
  type UseMutationOptions,
  queryOptions,
  useMutation,
  useQueryClient,
} from "@tanstack/react-query";

// Wire types of the Team API contract (docs/team-settings-and-invites.md).
// Imported as types only, so no server code reaches the client bundle.
import type {
  TeamDetail,
  TeamInvitation,
  TeamInviteLink,
  TeamRole,
} from "@/services/teams/types";

export type {
  TeamBillingSummary,
  TeamDetail,
  TeamInvitation,
  TeamInviteLink,
  TeamMember,
  TeamRole,
  TeamViewerPermissions,
} from "@/services/teams/types";

/** One entry of `GET /api/subrouter/teams`. Billing fields are optional until every server has them. */
export type TeamCatalogEntry = {
  readonly id: string;
  readonly name: string;
  readonly personal: boolean;
  readonly permissions?: { readonly use: boolean; readonly manageAccounts: boolean };
  readonly planId?: string | null;
  readonly seats?: number | null;
  readonly role?: TeamRole | null;
  readonly canManageBilling?: boolean;
  readonly memberCount?: number | null;
};

export type TeamCatalog = {
  readonly selectedTeamId: string | null;
  readonly teams: readonly TeamCatalogEntry[];
};

export type InviteResult = {
  readonly invitations: readonly TeamInvitation[];
  readonly failed: readonly { readonly email: string; readonly code: string }[];
};

export type CreatedInviteLink = { readonly link: TeamInviteLink; readonly url: string };

export type JoinLinkInfo = { readonly teamDisplayName: string; readonly alreadyMember: boolean };

export class TeamApiError extends Error {
  override readonly name = "TeamApiError";
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
  ) {
    super(message);
  }
}

const REQUEST_TIMEOUT_MS = 15_000;

function errorFromBody(status: number, body: unknown): TeamApiError {
  const error = (body as { error?: unknown } | null)?.error;
  if (error && typeof error === "object") {
    const { code, message } = error as { code?: unknown; message?: unknown };
    return new TeamApiError(
      status,
      typeof code === "string" ? code : `http_${status}`,
      typeof message === "string" ? message : "",
    );
  }
  // Older routes answer `{ error: "code" }`.
  if (typeof error === "string") return new TeamApiError(status, error, "");
  return new TeamApiError(status, `http_${status}`, "");
}

export async function teamRequest<T>(
  path: string,
  init: { method?: string; body?: unknown; signal?: AbortSignal } = {},
): Promise<T> {
  let response: Response;
  try {
    response = await fetch(path, {
      method: init.method ?? "GET",
      credentials: "same-origin",
      headers: {
        accept: "application/json",
        ...(init.body === undefined ? {} : { "content-type": "application/json" }),
      },
      body: init.body === undefined ? undefined : JSON.stringify(init.body),
      signal: init.signal ?? AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    });
  } catch {
    throw new TeamApiError(0, "network_error", "");
  }
  const text = await response.text();
  let body: unknown = null;
  if (text) {
    try {
      body = JSON.parse(text);
    } catch {
      body = null;
    }
  }
  if (!response.ok) throw errorFromBody(response.status, body);
  return body as T;
}

export function teamErrorCode(error: unknown): string {
  return error instanceof TeamApiError ? error.code : "unknown";
}

const teamPath = (teamId: string) => `/api/teams/${encodeURIComponent(teamId)}`;

export const teamApi = {
  catalog: (signal?: AbortSignal) => teamRequest<TeamCatalog>("/api/subrouter/teams", { signal }),
  detail: (teamId: string, signal?: AbortSignal) => teamRequest<TeamDetail>(teamPath(teamId), { signal }),
  create: (displayName: string) =>
    teamRequest<{ team: { id: string; displayName: string } }>("/api/teams", {
      method: "POST",
      body: { displayName },
    }),
  update: (teamId: string, patch: { displayName?: string; profileImageUrl?: string | null }) =>
    teamRequest<unknown>(teamPath(teamId), { method: "PATCH", body: patch }),
  remove: (teamId: string) => teamRequest<unknown>(teamPath(teamId), { method: "DELETE" }),
  invite: (teamId: string, emails: readonly string[], role: TeamRole) =>
    teamRequest<InviteResult>(`${teamPath(teamId)}/invitations`, {
      method: "POST",
      body: { emails, role },
    }),
  resendInvitation: (teamId: string, invitationId: string) =>
    teamRequest<{ invitation: TeamInvitation }>(
      `${teamPath(teamId)}/invitations/${encodeURIComponent(invitationId)}/resend`,
      { method: "POST" },
    ),
  revokeInvitation: (teamId: string, invitationId: string) =>
    teamRequest<unknown>(`${teamPath(teamId)}/invitations/${encodeURIComponent(invitationId)}`, {
      method: "DELETE",
    }),
  createLink: (teamId: string, input: { expiresInDays: 1 | 7 | 30 | null; maxUses: number | null }) =>
    teamRequest<CreatedInviteLink>(`${teamPath(teamId)}/links`, { method: "POST", body: input }),
  revokeLink: (teamId: string, linkId: string) =>
    teamRequest<unknown>(`${teamPath(teamId)}/links/${encodeURIComponent(linkId)}`, {
      method: "DELETE",
    }),
  changeRole: (teamId: string, userId: string, role: TeamRole) =>
    teamRequest<unknown>(`${teamPath(teamId)}/members/${encodeURIComponent(userId)}`, {
      method: "PATCH",
      body: { role },
    }),
  removeMember: (teamId: string, userId: string) =>
    teamRequest<unknown>(`${teamPath(teamId)}/members/${encodeURIComponent(userId)}`, {
      method: "DELETE",
    }),
  joinInfo: (token: string, signal?: AbortSignal) =>
    teamRequest<JoinLinkInfo>(`/api/teams/join/${encodeURIComponent(token)}`, { signal }),
  join: (token: string) =>
    teamRequest<{ teamId: string }>(`/api/teams/join/${encodeURIComponent(token)}`, {
      method: "POST",
    }),
  accept: (code: string) =>
    teamRequest<{ teamId: string }>("/api/teams/accept", { method: "POST", body: { code } }),
};

export const teamQueryKeys = {
  catalog: ["teams", "catalog"] as const,
  detail: (teamId: string) => ["teams", "detail", teamId] as const,
};

/** `GET /api/subrouter/teams`: the viewer's teams and the server-selected one. */
export const teamCatalogQuery = queryOptions({
  queryKey: teamQueryKeys.catalog,
  queryFn: ({ signal }) => teamApi.catalog(signal),
});

/** A 403 or 404 from the detail route means the viewer is not a member. */
export function isNotMemberError(error: unknown): boolean {
  return error instanceof TeamApiError && (error.status === 403 || error.status === 404);
}

/** `GET /api/teams/:teamId`: members, invitations, links, billing summary, viewer permissions. */
export function teamDetailQuery(teamId: string) {
  return queryOptions({
    queryKey: teamQueryKeys.detail(teamId),
    queryFn: ({ signal }) => teamApi.detail(teamId, signal),
    // 403/404 mean "not a member"; retrying cannot change that.
    retry: (failureCount, error) =>
      !(error instanceof TeamApiError && error.status >= 400 && error.status < 500) &&
      failureCount < 2,
  });
}

type DetailContext = { readonly previous: TeamDetail | undefined };

/**
 * Mutation options that apply `optimistic` to the cached team detail before
 * the request, restore the snapshot on failure, and refetch afterwards.
 * Exported as a factory so tests can drive it with a bare QueryClient.
 */
export function optimisticDetailMutation<Variables, Result>(
  queryClient: QueryClient,
  teamId: string,
  mutationFn: (variables: Variables) => Promise<Result>,
  optimistic: (detail: TeamDetail, variables: Variables) => TeamDetail,
): UseMutationOptions<Result, unknown, Variables, DetailContext> {
  const key = teamQueryKeys.detail(teamId);
  return {
    mutationFn,
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
  return useMutation({ mutationFn: () => teamApi.remove(teamId) });
}

/** After leaving or deleting a team: drop its detail and refresh the team scope. */
export async function forgetTeam(queryClient: QueryClient, teamId: string): Promise<void> {
  queryClient.removeQueries({ queryKey: teamQueryKeys.detail(teamId) });
  await invalidateTeamScope(queryClient);
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
