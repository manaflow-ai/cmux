import { DEVELOPMENT_STACK_PROJECT_ID } from "../auth/stackProject";

const IOS_DEVELOPMENT_NAMESPACE = /^dev\.cmux\.ios\.[A-Za-z0-9._-]+$/;
const MAC_DEVELOPMENT_NAMESPACE = /^mac:com\.cmuxterm\.app\.debug\.[A-Za-z0-9._-]+$/;
const STACK_TEAM_ID = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$/;

export { DEVELOPMENT_STACK_PROJECT_ID };

export type DevRelayRateLimitBypassEnv = {
  readonly CMUX_IROH_DEV_RATE_LIMIT_BYPASS_ENABLED?: string;
  readonly CMUX_IROH_DEV_RATE_LIMIT_BYPASS_TEAM_IDS?: string;
  readonly NEXT_PUBLIC_STACK_PROJECT_ID?: string;
};

/**
 * Only tagged debug bundle namespaces qualify. Release and internal beta
 * bundles deliberately have different namespace prefixes and never match.
 */
export function isDevelopmentRelayClientNamespace(
  clientNamespace: string,
): boolean {
  return IOS_DEVELOPMENT_NAMESPACE.test(clientNamespace) ||
    MAC_DEVELOPMENT_NAMESPACE.test(clientNamespace);
}

/** Parse the server-owned Stack team allowlist without accepting blank entries. */
export function parseDevRelayRateLimitBypassTeamIds(
  raw: string | undefined,
): ReadonlySet<string> {
  const values = (raw ?? "").split(",").map((value) => value.trim().toLowerCase());
  const ids = values.filter((value) => value.length > 0);
  if (ids.some((value) => !STACK_TEAM_ID.test(value))) return new Set();
  return new Set(ids);
}

/**
 * A bypass is valid only when the deployment explicitly opts in, is running
 * against the development Stack project, carries a tagged debug namespace,
 * and the authenticated user belongs to an operator-selected team.
 */
export function isAuthorizedDevRelayRateLimitBypass(input: {
  readonly clientNamespace: string;
  readonly teamIds: readonly string[];
  readonly env?: DevRelayRateLimitBypassEnv;
}): boolean {
  const env = input.env ?? process.env;
  if (env.CMUX_IROH_DEV_RATE_LIMIT_BYPASS_ENABLED !== "1") return false;
  if (env.NEXT_PUBLIC_STACK_PROJECT_ID !== DEVELOPMENT_STACK_PROJECT_ID) return false;
  if (!isDevelopmentRelayClientNamespace(input.clientNamespace)) return false;
  const allowedTeamIds = parseDevRelayRateLimitBypassTeamIds(
    env.CMUX_IROH_DEV_RATE_LIMIT_BYPASS_TEAM_IDS,
  );
  if (allowedTeamIds.size === 0) return false;
  return input.teamIds.some((teamId) => allowedTeamIds.has(teamId.trim().toLowerCase()));
}
