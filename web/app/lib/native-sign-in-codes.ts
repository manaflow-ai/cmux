import { createHash, randomBytes, timingSafeEqual } from "crypto";

/**
 * One-time sign-in codes for the native app hand-off (RFC 7636 PKCE, S256).
 *
 * After a browser sign-in, cmux.com stores a short-lived record bound to the
 * app's code challenge and callback scheme, and sends the app only the code.
 * The app redeems the code with its verifier over HTTPS; the session is
 * minted then, and its tokens travel in the response body only.
 *
 * Only the code's SHA-256 is stored. A record is consumed by its first
 * redemption whether or not the verifier matches, so a guessed or replayed
 * verifier burns the code.
 */

/** How long an issued code stays redeemable. */
export const NATIVE_SIGN_IN_CODE_TTL_MS = 60_000;

/** The only challenge method accepted. */
export const PKCE_METHOD_S256 = "S256";

/** A stored code. `codeHash` is the hex SHA-256 of the code. */
export type NativeSignInCodeRecord = {
  readonly codeHash: string;
  readonly codeChallenge: string;
  readonly scheme: string;
  readonly userId: string;
  /** The sign-in project that issued the code; redemption must be in the same one. */
  readonly issuer: string;
  readonly expiresAt: Date;
};

/** Storage for codes. `consume` removes and returns an unexpired record atomically. */
export type NativeSignInCodeStore = {
  insert: (record: NativeSignInCodeRecord) => Promise<void>;
  consume: (codeHash: string, now: Date) => Promise<NativeSignInCodeRecord | null>;
};

const CODE_CHALLENGE_PATTERN = /^[A-Za-z0-9_-]{43}$/;
const CODE_VERIFIER_PATTERN = /^[A-Za-z0-9._~-]{43,128}$/;
const CODE_PATTERN = /^[A-Za-z0-9_-]{43}$/;

/** A base64url SHA-256 challenge: exactly 43 characters. */
export function isValidCodeChallenge(value: unknown): value is string {
  return typeof value === "string" && CODE_CHALLENGE_PATTERN.test(value);
}

/** An RFC 7636 verifier: 43 to 128 unreserved characters. */
export function isValidCodeVerifier(value: unknown): value is string {
  return typeof value === "string" && CODE_VERIFIER_PATTERN.test(value);
}

/** An issued code: 32 random bytes, base64url. */
export function isValidNativeSignInCode(value: unknown): value is string {
  return typeof value === "string" && CODE_PATTERN.test(value);
}

/** `BASE64URL(SHA256(ASCII(verifier)))`. */
export function s256CodeChallenge(verifier: string): string {
  return createHash("sha256").update(verifier, "ascii").digest("base64url");
}

export function hashNativeSignInCode(code: string): string {
  return createHash("sha256").update(code, "utf8").digest("hex");
}

function constantTimeStringEqual(left: string, right: string): boolean {
  const a = Buffer.from(left, "utf8");
  const b = Buffer.from(right, "utf8");
  // Compare equal-length digests so the length difference does not leak timing.
  const da = createHash("sha256").update(a).digest();
  const db = createHash("sha256").update(b).digest();
  return timingSafeEqual(da, db) && a.length === b.length;
}

/**
 * Store a new code for `userId`, bound to the app's challenge and scheme, and
 * return the plaintext code. Throws when the challenge is malformed.
 */
export async function issueNativeSignInCode(
  store: NativeSignInCodeStore,
  input: { userId: string; codeChallenge: string; scheme: string; issuer: string },
  now: () => number = Date.now,
): Promise<string> {
  if (!isValidCodeChallenge(input.codeChallenge)) {
    throw new Error("invalid code challenge");
  }
  if (!input.userId || !input.scheme || !input.issuer) throw new Error("invalid code binding");
  const code = randomBytes(32).toString("base64url");
  await store.insert({
    codeHash: hashNativeSignInCode(code),
    codeChallenge: input.codeChallenge,
    scheme: input.scheme,
    userId: input.userId,
    issuer: input.issuer,
    expiresAt: new Date(now() + NATIVE_SIGN_IN_CODE_TTL_MS),
  });
  return code;
}

/**
 * Consume `code` and return its user when the verifier, the scheme and the
 * issuing sign-in project match. Every failure answers `null`, and the code
 * is gone after any attempt.
 */
export async function redeemNativeSignInCode(
  store: NativeSignInCodeStore,
  input: { code: unknown; codeVerifier: unknown; scheme: unknown; issuer: string },
  now: () => number = Date.now,
): Promise<{ userId: string; record: NativeSignInCodeRecord } | null> {
  const { code, codeVerifier, scheme } = input;
  if (!isValidNativeSignInCode(code) || typeof scheme !== "string" || !input.issuer) return null;
  const record = await store.consume(hashNativeSignInCode(code), new Date(now()));
  if (!record) return null;
  if (record.expiresAt.getTime() <= now()) return null;
  if (!isValidCodeVerifier(codeVerifier)) return null;
  // Every check runs, so the time taken does not say which one failed.
  const challengeMatches = constantTimeStringEqual(s256CodeChallenge(codeVerifier), record.codeChallenge);
  const schemeMatches = constantTimeStringEqual(scheme.trim().toLowerCase(), record.scheme);
  const issuerMatches = constantTimeStringEqual(input.issuer, record.issuer);
  if (!challengeMatches || !schemeMatches || !issuerMatches) return null;
  return { userId: record.userId, record };
}

/**
 * Put back a code whose verifier matched but whose session could not be
 * minted (a transient sign-in service failure), so the app's retry with the
 * same verifier can still succeed before the code's original expiry.
 */
export async function restoreNativeSignInCode(
  store: NativeSignInCodeStore,
  record: NativeSignInCodeRecord,
  now: () => number = Date.now,
): Promise<void> {
  if (record.expiresAt.getTime() <= now()) return;
  await store.insert(record);
}
