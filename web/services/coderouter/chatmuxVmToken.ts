// chatmux VM tokens: short-lived ES256 JWTs that chatmux (chatmux.dev) signs
// for each of its Freestyle VMs with a key held in an HSM. The Freestyle edge
// injects the token into the VM's requests, so the guest never holds it.
// coderouter verifies it against chatmux's public JWKS; no coderouter database
// row exists for these machines. A chatmux machine may use only accounts its
// Hexclave team shares (visibility "team"), never anyone's private account.
//
// The same shape is signed by cmux's own Cloud API for its machines (issuer
// `https://cmux-api/<environment>`, keys at that API's /.well-known/jwks.json),
// so coderouter trusts several issuers, each only with its own key set:
// - CODEROUTER_CHATMUX_JWKS_URL with CODEROUTER_CHATMUX_ISSUERS (one set), and
// - CODEROUTER_CHATMUX_TRUST, a JSON array of {"jwks": url, "issuers": [..]}.
// A token is checked only against the key set of the entry that lists its
// issuer, so one issuer's key can never sign for another. Off when neither is
// set.
import {
  createRemoteJWKSet,
  decodeJwt,
  decodeProtectedHeader,
  jwtVerify,
  type JWTVerifyGetKey,
} from "jose";

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

/** One trusted signer: its key set and the issuers it may sign as. */
export type ChatmuxTrust = { readonly keys: JWTVerifyGetKey; readonly issuers: ReadonlyArray<string> };
type Config = { readonly trusts: ReadonlyArray<ChatmuxTrust> };

// jose caches each set, refetches on an unknown kid, and rate-limits refetches.
const remote = new Map<string, JWTVerifyGetKey>();

function remoteKeys(url: string): JWTVerifyGetKey {
  let keys = remote.get(url);
  if (!keys) {
    keys = createRemoteJWKSet(new URL(url), { cooldownDuration: 60_000 });
    remote.set(url, keys);
  }
  return keys;
}

function issuerList(value: unknown): string[] {
  const items = typeof value === "string" ? value.split(",") : Array.isArray(value) ? value : [];
  return items.filter((s): s is string => typeof s === "string").map((s) => s.trim()).filter(Boolean);
}

/** The (JWKS URL, issuers) pairs the environment names; malformed entries are dropped. */
function trustedPairs(env: Record<string, string | undefined>): Array<{ url: string; issuers: string[] }> {
  const pairs = [{ url: env.CODEROUTER_CHATMUX_JWKS_URL?.trim() ?? "", issuers: issuerList(env.CODEROUTER_CHATMUX_ISSUERS) }];
  let extra: unknown = [];
  try {
    extra = JSON.parse(env.CODEROUTER_CHATMUX_TRUST?.trim() || "[]");
  } catch {
    extra = [];
  }
  for (const entry of Array.isArray(extra) ? extra : []) {
    const { jwks, issuers } = (entry ?? {}) as { jwks?: unknown; issuers?: unknown };
    pairs.push({ url: typeof jwks === "string" ? jwks.trim() : "", issuers: issuerList(issuers) });
  }
  return pairs.filter((p) => p.url.startsWith("https://") && p.issuers.length > 0);
}

/** The configured signers, or null when machine tokens are off. */
export function chatmuxConfig(env: Record<string, string | undefined> = process.env): Config | null {
  const trusts = trustedPairs(env).map(({ url, issuers }) => ({ keys: remoteKeys(url), issuers }));
  return trusts.length ? { trusts } : null;
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
    // The unverified issuer only picks which key set to verify against;
    // jwtVerify then checks it against that entry's issuers.
    const iss = decodeJwt(token).iss;
    for (const trust of config.trusts) {
      if (typeof iss !== "string" || !trust.issuers.includes(iss)) continue;
      const claims = await verifyWith(token, trust, now);
      if (claims) return claims;
    }
    return null;
  } catch {
    return null;
  }
}

async function verifyWith(token: string, trust: ChatmuxTrust, now: Date): Promise<ChatmuxVmClaims | null> {
  try {
    const { payload } = await jwtVerify(token, trust.keys, {
      algorithms: ["ES256"],
      issuer: [...trust.issuers],
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
