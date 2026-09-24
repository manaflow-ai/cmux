import { decodeProtectedHeader, jwtVerify, SignJWT } from "jose";
import { createSecretKey, randomUUID } from "node:crypto";

export const VM_AUTHORIZATION_HEADER = "x-cmux-authorization";
export const VM_AUTHORIZATION_AUDIENCE = "cmux-vm-model-plane";
export const VM_AUTHORIZATION_ALGORITHM = "HS256" as const;
export const VM_AUTHORIZATION_LIFETIME_SECONDS = 30 * 24 * 60 * 60;
const TOKEN_TYPE = "cmux-vm+jwt";
const KEY_ID = /^[a-zA-Z0-9_-]{1,64}$/;

export type VmAuthorizationClaims = {
  readonly vm_id: string;
  readonly team_id: string;
  readonly owner_id: string;
  readonly jti: string;
};

function secretKey(encoded: string): ReturnType<typeof createSecretKey> {
  const bytes = Buffer.from(encoded, "base64url");
  if (bytes.byteLength < 32 || bytes.byteLength > 128 || bytes.toString("base64url") !== encoded) {
    throw new Error("VM authorization key must be canonical base64url encoding of 32-128 random bytes");
  }
  return createSecretKey(bytes);
}

function signingKey() {
  const raw = process.env.CMUX_VM_AUTH_SIGNING_KEY?.trim();
  const kid = process.env.CMUX_VM_AUTH_SIGNING_KEY_ID?.trim();
  if (!raw || !kid || !KEY_ID.test(kid)) throw new Error("VM authorization signing key and key id are required");
  return { key: secretKey(raw), kid };
}

function verificationKey(kid: string) {
  if (!KEY_ID.test(kid)) throw new Error("invalid VM authorization key id");
  const current = signingKey();
  if (current.kid === kid) return current.key;
  const raw = process.env.CMUX_VM_AUTH_SIGNING_PREVIOUS_KEYS;
  if (raw) {
    // Do not echo configuration or JOSE input in errors.
    let keys: unknown;
    try { keys = JSON.parse(raw); } catch { throw new Error("invalid VM authorization key configuration"); }
    if (keys && typeof keys === "object" && !Array.isArray(keys) && Object.hasOwn(keys, kid)) {
      const encoded = (keys as Record<string, unknown>)[kid];
      if (typeof encoded === "string") return secretKey(encoded);
    }
  }
  throw new Error("unknown VM authorization key");
}

function identifier(value: unknown): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= 256 && !/[\s\x00-\x1f\x7f]/.test(value);
}

export async function signVmAuthorization(input: {
  readonly vmId: string;
  readonly teamId: string;
  readonly ownerId: string;
  readonly expiresAt: Date;
  readonly now?: Date;
}): Promise<string> {
  const key = signingKey();
  const iat = Math.floor((input.now ?? new Date()).getTime() / 1000);
  const exp = Math.floor(input.expiresAt.getTime() / 1000);
  if (![input.vmId, input.teamId, input.ownerId].every(identifier) || !validLifetime(iat, exp)) {
    throw new Error("invalid VM authorization claims");
  }
  return await new SignJWT({ vm_id: input.vmId, team_id: input.teamId, owner_id: input.ownerId })
    .setProtectedHeader({ alg: VM_AUTHORIZATION_ALGORITHM, typ: TOKEN_TYPE, kid: key.kid })
    .setIssuer("cmux")
    .setAudience(VM_AUTHORIZATION_AUDIENCE)
    .setJti(randomUUID())
    .setIssuedAt(iat)
    .setExpirationTime(exp)
    .sign(key.key);
}

function validLifetime(iat: unknown, exp: unknown): boolean {
  return typeof iat === "number" && Number.isSafeInteger(iat) && iat >= 0 &&
    typeof exp === "number" && Number.isSafeInteger(exp) && exp > iat && exp - iat <= VM_AUTHORIZATION_LIFETIME_SECONDS;
}

/** Local signature verification precedes any database access. No token or JOSE error escapes. */
export async function verifyVmAuthorization(token: string, now = new Date()): Promise<VmAuthorizationClaims | null> {
  try {
    if (token.length > 4096 || !/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(token)) return null;
    const header = decodeProtectedHeader(token);
    if (typeof header.kid !== "string") return null;
    const { payload } = await jwtVerify(token, verificationKey(header.kid), {
      algorithms: [VM_AUTHORIZATION_ALGORITHM],
      typ: TOKEN_TYPE,
      issuer: "cmux",
      audience: VM_AUTHORIZATION_AUDIENCE,
      requiredClaims: ["vm_id", "team_id", "owner_id", "jti", "iat", "exp"],
      maxTokenAge: VM_AUTHORIZATION_LIFETIME_SECONDS,
      currentDate: now,
    });
    if (!validLifetime(payload.iat, payload.exp) ||
        !identifier(payload.vm_id) || !identifier(payload.team_id) ||
        !identifier(payload.owner_id) || !identifier(payload.jti)) return null;
    return { vm_id: payload.vm_id, team_id: payload.team_id, owner_id: payload.owner_id, jti: payload.jti };
  } catch {
    return null;
  }
}
