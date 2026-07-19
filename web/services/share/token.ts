// Pure token-minting logic for multiplayer workspace sharing, kept separate
// from the HTTP routes so it is testable without the auth graph. Mirrors
// services/relay/token.ts: the web API is the issuer and holds the Ed25519
// PRIVATE key (`CMUX_SHARE_JWT_PRIVATE_KEY_PEM`); the share worker
// (workers/share) holds only the PUBLIC key and verifies offline. A minted
// token is a short-TTL EdDSA JWT with `iss=cmux`, `aud=cmux-share`,
// `sub=<user>`, bound to one share code via the `code` claim; `host=true`
// appears only on tokens minted by the session-create endpoint.

import {
  createPrivateKey,
  randomBytes,
  sign as edSign,
  type KeyObject,
} from "node:crypto";

export const SHARE_TOKEN_ISS = "cmux";
export const SHARE_TOKEN_AUD = "cmux-share";
export const SHARE_TOKEN_TTL_SECONDS = 300; // short-lived; clients refresh on reconnect

/** 22 base62 chars ≈ 131 bits of entropy: unguessable, single-session. */
export const SHARE_CODE_LENGTH = 22;
const SHARE_CODE_ALPHABET =
  "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
export const SHARE_CODE_RE = /^[A-Za-z0-9]{8,64}$/;

export function generateShareCode(): string {
  const bytes = randomBytes(SHARE_CODE_LENGTH);
  let code = "";
  for (let i = 0; i < SHARE_CODE_LENGTH; i += 1) {
    // 256 % 62 bias is ~0.5% per char; irrelevant at 131 bits.
    code += SHARE_CODE_ALPHABET[(bytes[i] as number) % SHARE_CODE_ALPHABET.length];
  }
  return code;
}

export function isValidShareCode(code: string): boolean {
  return SHARE_CODE_RE.test(code);
}

// Parse the signing key once and cache it keyed on the PEM value.
let cached: { pem: string; key: KeyObject } | null = null;

export function shareSigningKey(): KeyObject | null {
  const pem = process.env.CMUX_SHARE_JWT_PRIVATE_KEY_PEM;
  if (!pem || !pem.includes("BEGIN")) return null;
  if (cached && cached.pem === pem) return cached.key;
  try {
    const key = createPrivateKey(pem);
    // The worker's baked public key is Ed25519; any other key type would sign
    // tokens no worker can verify. Treat as unconfigured (-> 503).
    if (key.asymmetricKeyType !== "ed25519") return null;
    cached = { pem, key };
    return key;
  } catch {
    return null;
  }
}

/** WebSocket URL for a share session, host and guest alike. */
export function shareSessionWsUrl(code: string): string {
  const base = (process.env.CMUX_SHARE_WS_BASE_URL ?? "wss://share.cmux.dev").replace(
    /\/$/,
    "",
  );
  return `${base}/v1/share/sessions/${code}/ws`;
}

/** Browser URL a host hands to guests. */
export function sharePageUrl(code: string): string {
  const base = (process.env.CMUX_SHARE_PAGE_BASE_URL ?? "https://cmux.com").replace(
    /\/$/,
    "",
  );
  return `${base}/share/${code}`;
}

function b64url(input: Buffer | string): string {
  return Buffer.from(input).toString("base64url");
}

/**
 * Mint a compact EdDSA (Ed25519) JWT. Ed25519 signs the raw message (no
 * prehash), so the digest passed to `sign` is `null`. Byte-compatible with
 * what `jose` produces and what workers/share/src/jwt.ts verifies.
 */
export function mintShareToken(params: {
  sub: string;
  email: string;
  code: string;
  host: boolean;
  /** True only on tokens minted by the session-create endpoint: the only
   * tokens allowed to materialize a new session in the DO. A host-claim
   * refresh token can reconnect to its session but never create one, so
   * nobody can squat sessions at codes they did not mint. */
  create?: boolean;
  key: KeyObject;
  nowSeconds: number;
}): { token: string; expiresAt: number } {
  const { sub, email, code, host, create, key, nowSeconds } = params;
  const expiresAt = nowSeconds + SHARE_TOKEN_TTL_SECONDS;
  const header = { alg: "EdDSA", typ: "JWT" };
  const payload: Record<string, unknown> = {
    iss: SHARE_TOKEN_ISS,
    aud: SHARE_TOKEN_AUD,
    sub,
    email,
    code,
    host,
    ...(create ? { create: true } : {}),
    iat: nowSeconds,
    exp: expiresAt,
  };
  const signingInput = `${b64url(JSON.stringify(header))}.${b64url(
    JSON.stringify(payload),
  )}`;
  const signature = edSign(null, Buffer.from(signingInput), key);
  return { token: `${signingInput}.${b64url(signature)}`, expiresAt };
}
