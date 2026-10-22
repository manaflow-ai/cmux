// The consent step of the MCP authorization flow, shared by the
// `/authorize/mcp` page (which shows it) and `POST /api/oauth/authorize`
// (which records the decision). Both re-validate the full request, so the
// form's hidden fields are never trusted on their own.

import { getStackServerApp } from "../../app/lib/stack";
import {
  authorizationRedirect,
  issueAuthorizationCode,
  MCP_SCOPES,
  validateAuthorizationRequest,
  type AuthorizationRequest,
  type McpScope,
} from "./oauth";
import { mcpOauthDbStore } from "./oauthStore";

/** Authorization request parameters the consent form carries through unchanged. */
export const AUTHORIZATION_PARAM_NAMES = [
  "client_id",
  "redirect_uri",
  "response_type",
  "state",
  "code_challenge",
  "code_challenge_method",
  "scope",
  "resource",
] as const;

export const MCP_SCOPE_DESCRIPTIONS: Record<McpScope, string> = {
  "machines:read": "See your Cloud machines, their status, and your plan's machine limits",
  "machines:write": "Create, pause, resume, and delete Cloud machines",
  "terminals:read": "List and read terminals on your machines",
  "terminals:write": "Type into terminals on your machines",
  "agents:run": "Start coding agents (Claude Code, Codex, OpenCode, Pi) on your machines",
};

export type ConsentTeam = { readonly id: string; readonly name: string };

export type ConsentUser = {
  readonly id: string;
  readonly email: string | null;
  readonly name: string | null;
  readonly teams: readonly ConsentTeam[];
  readonly selectedTeamId: string | null;
};

type StackUserForConsent = {
  readonly id: string;
  readonly primaryEmail: string | null;
  readonly displayName: string | null;
  readonly isAnonymous?: boolean;
  readonly selectedTeam?: { readonly id: string } | null;
  readonly listTeams: () => Promise<ReadonlyArray<{ readonly id: string; readonly displayName: string }>>;
};

async function consentUserFrom(user: StackUserForConsent | null): Promise<ConsentUser | null> {
  if (!user || user.isAnonymous) return null;
  const teams = (await user.listTeams()).map((team) => ({ id: team.id, name: team.displayName }));
  return {
    id: user.id,
    email: user.primaryEmail,
    name: user.displayName,
    teams,
    selectedTeamId: user.selectedTeam?.id ?? null,
  };
}

/** The signed-in browser user (session cookie), for the page. */
export async function consentUserFromCookies(): Promise<ConsentUser | null> {
  return consentUserFrom(await getStackServerApp().getUser({ or: "return-null" }) as StackUserForConsent | null);
}

/** The signed-in browser user for a form POST. */
export async function consentUserFromRequest(request: Request): Promise<ConsentUser | null> {
  const user = await getStackServerApp().getUser({
    tokenStore: request as unknown as { headers: { get(name: string): string | null } },
    or: "return-null",
  });
  return consentUserFrom(user as StackUserForConsent | null);
}

export function authorizationParams(source: URLSearchParams): URLSearchParams {
  const params = new URLSearchParams();
  for (const name of AUTHORIZATION_PARAM_NAMES) {
    const value = source.get(name);
    if (value !== null) params.set(name, value);
  }
  return params;
}

export function validateConsentRequest(params: URLSearchParams, origin: string) {
  return validateAuthorizationRequest(mcpOauthDbStore(), params, origin);
}

/**
 * The team a grant bills to. A user with teams must pick one of them (there is
 * no personal fallback once a team exists, matching `/api/vm`); a user with
 * none bills to their own account.
 */
export function consentTeamId(user: ConsentUser, requested: string | null): string | null | undefined {
  if (user.teams.length === 0) return null;
  const teamId = requested ?? user.selectedTeamId ?? user.teams[0]!.id;
  return user.teams.some((team) => team.id === teamId) ? teamId : undefined;
}

export function approvedScopes(form: URLSearchParams, request: AuthorizationRequest): McpScope[] {
  const approved = form.getAll("approved_scope");
  return MCP_SCOPES.filter((scope) => request.scopes.includes(scope) && approved.includes(scope));
}

export async function approveConsent(
  request: AuthorizationRequest,
  user: ConsentUser,
  teamId: string | null,
  scopes: readonly McpScope[],
  origin: string,
): Promise<string> {
  const code = await issueAuthorizationCode(mcpOauthDbStore(), request, { stackUserId: user.id, teamId, scopes });
  return authorizationRedirect(request.redirectUri, origin, { code, state: request.state });
}

export function denyConsent(request: AuthorizationRequest, origin: string): string {
  return authorizationRedirect(request.redirectUri, origin, {
    error: "access_denied",
    error_description: "The user denied the request.",
    state: request.state,
  });
}
