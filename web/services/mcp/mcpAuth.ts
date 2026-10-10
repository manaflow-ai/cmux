import type { AuthedUser } from "../vms/auth";
import { verifyStackUserById } from "../vms/auth";
import { grantForAccessToken, hashToken, isMcpAccessToken, type McpOauthGrant, type McpOauthStore } from "./oauth";

export type McpOauthCaller = { readonly grant: McpOauthGrant; readonly user: AuthedUser };

export type McpBearerAuth =
  | { readonly kind: "none" }
  | { readonly kind: "invalid" }
  | { readonly kind: "oauth"; readonly caller: McpOauthCaller };

// A connector calls `/api/mcp` several times per user message. Cache a
// resolved token briefly so each call does not cost a Stack lookup; a revoked
// grant stops working within this window.
const CALLER_CACHE_TTL_MS = 30_000;
const MAX_CALLER_CACHE_ENTRIES = 512;
const callerCache = new Map<string, { caller: McpOauthCaller; expiresAt: number }>();

export function clearMcpCallerCacheForTests(): void {
  callerCache.clear();
}

function bearerFrom(request: Request): string | null {
  const authorization = request.headers.get("authorization");
  if (!authorization?.toLowerCase().startsWith("bearer ")) return null;
  return authorization.slice("bearer ".length).trim() || null;
}

/**
 * Authenticates an MCP OAuth bearer. `none` means the request carries no MCP
 * token (it may still carry a Stack session); `invalid` means it carries one
 * that is expired, revoked, or no longer matches the account's teams.
 */
export async function authenticateMcpBearer(
  request: Request,
  store: McpOauthStore,
  options: {
    readonly resolveUser?: (userId: string, teamId: string | null) => Promise<AuthedUser | null>;
    readonly now?: Date;
  } = {},
): Promise<McpBearerAuth> {
  const token = bearerFrom(request);
  if (!token || !isMcpAccessToken(token)) return { kind: "none" };
  const now = options.now ?? new Date();
  const key = hashToken(token);
  const cached = callerCache.get(key);
  if (cached && cached.expiresAt > now.getTime()) return { kind: "oauth", caller: cached.caller };
  const grant = await grantForAccessToken(store, token, now);
  if (!grant) return { kind: "invalid" };
  const resolveUser = options.resolveUser ?? ((userId, teamId) => verifyStackUserById(userId, { requestedTeamId: teamId }));
  const user = await resolveUser(grant.stackUserId, grant.teamId);
  if (!user || user.isAnonymous) return { kind: "invalid" };
  // A user who left the grant's team keeps no access to its machines.
  if (grant.teamId && !user.teamIds.includes(grant.teamId)) return { kind: "invalid" };
  const caller = { grant, user };
  if (callerCache.size >= MAX_CALLER_CACHE_ENTRIES) callerCache.delete(callerCache.keys().next().value!);
  callerCache.set(key, { caller, expiresAt: now.getTime() + CALLER_CACHE_TTL_MS });
  void store.touchGrant(grant.id, now).catch(() => undefined);
  return { kind: "oauth", caller };
}
