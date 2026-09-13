import type { CodeRouterCredential, CodexCredential } from "./types";

export type CodexOwner = { readonly userId: string; readonly workspaceId: string };
const AUTH_CLAIM = "https://api.openai.com/auth";
const OWNER_PREFIX = "codex-owner-v1:";

export class CodexOwnerMismatch extends Error {
  constructor() { super("Codex credential owner is missing or changed"); }
}

/** Claims select the owner; the provider validates token authenticity on use. */
export function codexOwner(credential: Pick<CodexCredential, "idToken" | "accessToken" | "accountId" | "userId">): CodexOwner {
  const claims = [jwtClaims(credential.idToken), jwtClaims(credential.accessToken)];
  const users = claimValues(claims, ["chatgpt_user_id"]);
  if (users.size === 0) {
    const legacyUser = record(claims[0][AUTH_CLAIM]).user_id;
    if (legacyUser !== undefined) {
      if (!validID(legacyUser)) throw new CodexOwnerMismatch();
      users.add(legacyUser);
    }
  }
  const workspaces = claimValues(claims, ["chatgpt_account_id"]);
  // Email, JWT subject and organization membership are not user/workspace claims.
  if (users.size !== 1 || workspaces.size !== 1) throw new CodexOwnerMismatch();
  const userId = [...users][0];
  const workspaceId = [...workspaces][0];
  if (credential.accountId !== workspaceId || (credential.userId !== undefined && credential.userId !== userId)) {
    throw new CodexOwnerMismatch();
  }
  return { userId, workspaceId };
}

export function withCodexOwner(credential: CodexCredential): CodexCredential & { readonly userId: string } {
  const owner = codexOwner(credential);
  const claims = jwtClaims(credential.idToken);
  const email = record(claims["https://api.openai.com/profile"]).email ?? claims.email;
  return { ...credential, userId: owner.userId, ...(typeof email === "string" && email.trim() ? { email: email.trim() } : {}) };
}

export function assertSameCodexOwner(before: CodexCredential, after: CodexCredential): void {
  const previous = codexOwner(before);
  const next = codexOwner(after);
  if (previous.userId !== next.userId || previous.workspaceId !== next.workspaceId) throw new CodexOwnerMismatch();
}

export function providerIdentityKey(credential: CodeRouterCredential): string {
  if (credential.provider !== "codex") return credential.accountId;
  const owner = codexOwner(credential);
  return OWNER_PREFIX + Buffer.from(JSON.stringify([owner.userId, owner.workspaceId])).toString("base64url");
}

export function ownerFromProviderKey(value: string): CodexOwner | null {
  if (!value.startsWith(OWNER_PREFIX)) return null;
  try {
    const owner: unknown = JSON.parse(Buffer.from(value.slice(OWNER_PREFIX.length), "base64url").toString("utf8"));
    return Array.isArray(owner) && owner.length === 2 && owner.every(validID)
      ? { userId: owner[0], workspaceId: owner[1] }
      : null;
  } catch { return null; }
}

function claimValues(claims: readonly Record<string, unknown>[], names: readonly string[]): Set<string> {
  const values = new Set<string>();
  for (const claim of claims) {
    const nested = record(claim[AUTH_CLAIM]);
    for (const name of names) {
      for (const value of [claim[name], nested[name]]) {
        if (value === undefined || value === null) continue;
        if (!validID(value)) throw new CodexOwnerMismatch();
        values.add(value);
      }
    }
  }
  return values;
}

function validID(value: unknown): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= 512 && value.trim() === value && !/[\u0000-\u0020\u007f]/.test(value);
}

function jwtClaims(token: string): Record<string, unknown> {
  try { return record(JSON.parse(Buffer.from(token.split(".")[1], "base64url").toString("utf8"))); }
  catch { return {}; }
}

function record(value: unknown): Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value) ? value as Record<string, unknown> : {};
}
