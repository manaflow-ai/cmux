// chatmux VM tokens: short-lived ES256 JWTs that chatmux (chatmux.dev) signs
// for each of its Freestyle VMs with a key held in an HSM. The Freestyle edge
// injects the token into the VM's requests, so the guest never holds it.
// coderouter verifies it against chatmux's public JWKS; no coderouter database
// row exists for these machines. A chatmux machine may use only accounts its
// Hexclave team shares (visibility "team"), never anyone's private account.
//
// Off unless both CODEROUTER_CHATMUX_JWKS_URL and CODEROUTER_CHATMUX_ISSUERS
// are set.
import { createRemoteJWKSet, decodeProtectedHeader, jwtVerify, type JWTVerifyGetKey } from "jose";

export const CHATMUX_VM_AUTHORIZATION_HEADER = "x-chatmux-vm-authorization";
export const CHATMUX_VM_AUDIENCE = "coderouter";
/** chatmux signs for one hour and rewrites the edge rule hourly. */
export const CHATMUX_VM_TOKEN_MAX_LIFETIME_SECONDS = 60 * 60;
const ROLES = new Set(["browser", "dev", "worker"]);

export type ChatmuxVmClaims = {
  /** `vm:<freestyle vm id>`. */
  readonly sub: string;
  readonly jti: string;
  readonly team_id: string;
  readonly owner_id: string;
  readonly role: "browser" | "dev" | "worker";
  readonly iss: string;
};

type Config = { readonly keys: JWTVerifyGetKey; readonly issuers: ReadonlyArray<string> };

let remote: { url: string; keys: JWTVerifyGetKey } | null = null;

/** The configured key set and issuers, or null when chatmux tokens are off. */
export function chatmuxConfig(env: Record<string, string | undefined> = process.env): Config | null {
  const url = env.CODEROUTER_CHATMUX_JWKS_URL?.trim();
  const issuers = (env.CODEROUTER_CHATMUX_ISSUERS ?? "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  if (!url || !issuers.length || !url.startsWith("https://")) return null;
  // jose caches the set, refetches on an unknown kid, and rate-limits refetches.
  if (remote?.url !== url) remote = { url, keys: createRemoteJWKSet(new URL(url), { cooldownDuration: 60_000 }) };
  return { keys: remote.keys, issuers };
}

function identifier(value: unknown): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= 256 &&
    ![...value].some((c) => c.charCodeAt(0) <= 0x20 || c.charCodeAt(0) === 0x7f || /\s/.test(c));
}

function validLifetime(iat: unknown, exp: unknown): boolean {
  return typeof iat === "number" && typeof exp === "number" && exp > iat &&
    exp - iat <= CHATMUX_VM_TOKEN_MAX_LIFETIME_SECONDS;
}

/** The typed claims of a verified payload, or null when one is missing or malformed. */
function claimsFrom(payload: Record<string, unknown>): ChatmuxVmClaims | null {
  const { sub, jti, team_id, owner_id, role, iss } = payload;
  if (!validLifetime(payload.iat, payload.exp)) return null;
  if (![sub, jti, team_id, owner_id].every(identifier) || typeof iss !== "string") return null;
  if (!(sub as string).startsWith("vm:") || typeof role !== "string" || !ROLES.has(role)) return null;
  return {
    sub: sub as string,
    jti: jti as string,
    team_id: team_id as string,
    owner_id: owner_id as string,
    role: role as ChatmuxVmClaims["role"],
    iss,
  };
}

/**
 * Verifies a chatmux VM token locally (signature, issuer, audience, one-hour
 * lifetime, required claims). No token, configuration, or JOSE error escapes.
 */
export async function verifyChatmuxVmToken(
  token: string,
  config: Config | null = chatmuxConfig(),
  now = new Date(),
): Promise<ChatmuxVmClaims | null> {
  if (!config) return null;
  try {
    if (token.length > 4096 || !/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(token)) return null;
    const header = decodeProtectedHeader(token);
    if (header.alg !== "ES256" || typeof header.kid !== "string" || !/^[\w.-]{1,128}$/.test(header.kid)) return null;
    const { payload } = await jwtVerify(token, config.keys, {
      algorithms: ["ES256"],
      issuer: [...config.issuers],
      audience: CHATMUX_VM_AUDIENCE,
      requiredClaims: ["sub", "jti", "team_id", "owner_id", "role", "iat", "exp"],
      maxTokenAge: CHATMUX_VM_TOKEN_MAX_LIFETIME_SECONDS,
      clockTolerance: 60,
      currentDate: now,
    });
    return claimsFrom(payload);
  } catch {
    return null;
  }
}
