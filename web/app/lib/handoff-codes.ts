import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { and, asc, eq, gt, inArray, isNull, lte } from "drizzle-orm";
import { cloudDb } from "../../db/client";
import { authHandoffCodes } from "../../db/schema";

/**
 * One-time sign-in hand-off codes: an authorization code with PKCE (S256),
 * shared by every cmux.com flow that hands a signed-in person to another
 * client without putting a token in a URL (the Cloud console today).
 *
 * - The code is 256 random bits, base64url. Only its SHA-256 is stored.
 * - A code lives at most HANDOFF_CODE_MAX_TTL_MS and is bound to the user,
 *   the client id, the redirect URI and the PKCE code challenge.
 * - Redeeming consumes it first, in one atomic update, and only then checks
 *   the binding: any wrong guess with a real code burns it, and a second
 *   redemption of the same code always fails.
 *
 * Client authentication and the redirect URI allowlist belong to the caller
 * (for the console: services/auth/consoleSignIn.ts).
 */

export const HANDOFF_CODE_MAX_TTL_MS = 60_000;
const CODE_PATTERN = /^[A-Za-z0-9_-]{43}$/;
const CHALLENGE_PATTERN = /^[A-Za-z0-9_-]{43}$/;
/** RFC 7636 section 4.1. */
const VERIFIER_PATTERN = /^[A-Za-z0-9\-._~]{43,128}$/;
const SWEEP_LIMIT = 100;
const SWEEP_GRACE_MS = 10 * 60_000;

export type HandoffCodeRow = {
  readonly codeHash: string;
  readonly clientId: string;
  readonly redirectUri: string;
  readonly userId: string;
  readonly codeChallenge: string;
  readonly expiresAt: Date;
};

export type HandoffCodeBinding = Pick<HandoffCodeRow, "clientId" | "redirectUri" | "userId" | "codeChallenge">;

export interface HandoffCodeStore {
  insert(row: HandoffCodeRow, now: Date): Promise<void>;
  /** Marks the code consumed and returns it, only if it was unconsumed and unexpired; atomically. */
  consume(codeHash: string, now: Date): Promise<HandoffCodeBinding | null>;
}

const base64url = (bytes: Buffer): string => bytes.toString("base64url");

export const sha256Hex = (value: string): string => createHash("sha256").update(value, "utf8").digest("hex");

/** The S256 code challenge of a PKCE verifier. */
export const s256Challenge = (verifier: string): string => base64url(createHash("sha256").update(verifier, "ascii").digest());

/** Constant-time equality for strings of any length (compares their digests). */
export const constantTimeEqual = (a: string, b: string): boolean =>
  timingSafeEqual(createHash("sha256").update(a, "utf8").digest(), createHash("sha256").update(b, "utf8").digest());

export const isCodeChallenge = (value: string): boolean => CHALLENGE_PATTERN.test(value);
export const isCodeVerifier = (value: string): boolean => VERIFIER_PATTERN.test(value);

/** Issues a code for a validated client, redirect URI and challenge; returns the plaintext code (never stored). */
export async function issueHandoffCode(
  store: HandoffCodeStore,
  input: { clientId: string; redirectUri: string; userId: string; codeChallenge: string; now: Date; ttlMs?: number },
): Promise<string> {
  if (!isCodeChallenge(input.codeChallenge)) throw new Error("invalid code challenge");
  const ttl = Math.min(input.ttlMs ?? HANDOFF_CODE_MAX_TTL_MS, HANDOFF_CODE_MAX_TTL_MS);
  const code = base64url(randomBytes(32));
  await store.insert(
    {
      codeHash: sha256Hex(code),
      clientId: input.clientId,
      redirectUri: input.redirectUri,
      userId: input.userId,
      codeChallenge: input.codeChallenge,
      expiresAt: new Date(input.now.getTime() + ttl),
    },
    input.now,
  );
  return code;
}

export type HandoffRedeemFailure = "malformed" | "unknown_or_used" | "client_mismatch" | "redirect_mismatch" | "pkce_mismatch";

/**
 * Consumes `code` and returns its user when the client, redirect URI and PKCE
 * verifier all match. The failure reason is for server logs only; callers
 * answer every failure the same way.
 */
export async function redeemHandoffCode(
  store: HandoffCodeStore,
  input: { code: string; clientId: string; redirectUri: string; codeVerifier: string; now: Date },
): Promise<{ ok: true; userId: string } | { ok: false; reason: HandoffRedeemFailure }> {
  if (!CODE_PATTERN.test(input.code)) return { ok: false, reason: "malformed" };
  const row = await store.consume(sha256Hex(input.code), input.now);
  if (!row) return { ok: false, reason: "unknown_or_used" };
  // Every check runs, so the time taken does not say which one failed.
  const clientOk = constantTimeEqual(row.clientId, input.clientId);
  const redirectOk = constantTimeEqual(row.redirectUri, input.redirectUri);
  const pkceOk = isCodeVerifier(input.codeVerifier) && constantTimeEqual(row.codeChallenge, s256Challenge(input.codeVerifier));
  if (!clientOk) return { ok: false, reason: "client_mismatch" };
  if (!redirectOk) return { ok: false, reason: "redirect_mismatch" };
  if (!pkceOk) return { ok: false, reason: "pkce_mismatch" };
  return { ok: true, userId: row.userId };
}

/**
 * Opportunistic, bounded cleanup of long-expired codes, after the new code is stored. Best effort:
 * a failed sweep never fails the sign-in (the next issue retries it; expired rows are inert).
 */
export async function sweepExpiredHandoffCodes(sweep: () => PromiseLike<unknown>): Promise<void> {
  try {
    await sweep();
  } catch {
    console.warn("auth.handoff_codes.sweep_failed");
  }
}

/** The Postgres store (table auth_handoff_codes). */
export function createDbHandoffCodeStore(db: () => ReturnType<typeof cloudDb> = cloudDb): HandoffCodeStore {
  return {
    async insert(row, now) {
      const database = db();
      await database.insert(authHandoffCodes).values({ ...row, createdAt: now });
      await sweepExpiredHandoffCodes(() => database.delete(authHandoffCodes).where(
        inArray(
          authHandoffCodes.codeHash,
          database
            .select({ hash: authHandoffCodes.codeHash })
            .from(authHandoffCodes)
            .where(lte(authHandoffCodes.expiresAt, new Date(now.getTime() - SWEEP_GRACE_MS)))
            .orderBy(asc(authHandoffCodes.expiresAt))
            .limit(SWEEP_LIMIT),
        ),
      ));
    },
    async consume(codeHash, now) {
      const [row] = await db()
        .update(authHandoffCodes)
        .set({ consumedAt: now })
        .where(and(eq(authHandoffCodes.codeHash, codeHash), isNull(authHandoffCodes.consumedAt), gt(authHandoffCodes.expiresAt, now)))
        .returning({
          clientId: authHandoffCodes.clientId,
          redirectUri: authHandoffCodes.redirectUri,
          userId: authHandoffCodes.userId,
          codeChallenge: authHandoffCodes.codeChallenge,
        });
      return row ?? null;
    },
  };
}

/** An in-process store with the same single-use semantics, for tests and `next dev` without a database. */
export function createMemoryHandoffCodeStore(): HandoffCodeStore & { readonly rows: Map<string, HandoffCodeRow & { consumedAt: Date | null }> } {
  const rows = new Map<string, HandoffCodeRow & { consumedAt: Date | null }>();
  return {
    rows,
    async insert(row) {
      if (rows.has(row.codeHash)) throw new Error("duplicate code");
      rows.set(row.codeHash, { ...row, consumedAt: null });
    },
    async consume(codeHash, now) {
      const row = rows.get(codeHash);
      if (!row || row.consumedAt || row.expiresAt.getTime() <= now.getTime()) return null;
      row.consumedAt = now;
      return { clientId: row.clientId, redirectUri: row.redirectUri, userId: row.userId, codeChallenge: row.codeChallenge };
    },
  };
}
