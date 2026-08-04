import { randomBytes } from "node:crypto";
import { and, asc, count, eq, gt, isNull, lte, sql } from "drizzle-orm";
import { checkRateLimit } from "@vercel/firewall";
import { env } from "../../app/env";
import { getStackServerApp } from "../../app/lib/stack";
import { cloudDb } from "../../db/client";
import { irohEnrollmentTokens } from "../../db/schema";
import { unauthorized, verifyRequest } from "../vms/auth";
import { enforceBrowserMutationProtection, jsonResponse } from "../vms/routeHelpers";
import { IrohConflictError, IrohQuotaExceededError } from "./errors";
import { sha256 } from "./model";
import { assertIrohUserMutationAllowed } from "./repository";
import { irohErrorResponse } from "./routeHandler";

export const IROH_ENROLLMENT_TOKEN_LIFETIME_MS = 15 * 60 * 1_000;
export const IROH_ENROLLMENT_TOKEN_BYTES = 32;
/** Outstanding = unconsumed and unexpired, counted per user at mint time. */
export const IROH_ENROLLMENT_MAX_OUTSTANDING_TOKENS = 8;
/** Mirrors the vault CLI device-flow session lifetime (auth/poll). */
export const IROH_ENROLLMENT_SESSION_LIFETIME_MS = 90 * 24 * 60 * 60 * 1_000;

const MAX_BODY_BYTES = 64 * 1_024;
/** 32 random bytes encode to exactly 43 unpadded base64url characters. */
const ENROLLMENT_TOKEN_PATTERN = /^[A-Za-z0-9_-]{43}$/;
const MAX_TOKEN_FIELD_LENGTH = 128;
const EXPIRED_TOKEN_GC_AGE_MS = 60 * 60 * 1_000;

export type IrohEnrollmentSessionTokens = {
  readonly accessToken: string;
  readonly refreshToken: string;
};

export type IrohEnrollmentStoreShape = {
  /**
   * Persists the token hash under the account-deletion fence and a per-user
   * advisory lock, enforcing the outstanding-token cap atomically. Throws
   * IrohQuotaExceededError when the cap is reached.
   */
  readonly mintToken: (input: {
    readonly userId: string;
    readonly tokenHash: string;
    readonly now: Date;
    readonly expiresAt: Date;
  }) => Promise<void>;
  /**
   * Single-use consume: matches an unconsumed, unexpired row and stamps
   * consumed_at in one atomic UPDATE, so a concurrent double-spend fails for
   * the loser. Returns null without distinguishing missing/consumed/expired.
   */
  readonly consumeToken: (input: {
    readonly tokenHash: string;
    readonly now: Date;
  }) => Promise<{ readonly userId: string } | null>;
};

export type IrohEnrollmentDependencies = {
  readonly verify?: typeof verifyRequest;
  readonly store?: IrohEnrollmentStoreShape;
  readonly mintSession?: (userId: string) => Promise<IrohEnrollmentSessionTokens | null>;
  readonly rateLimit?: (request: Request) => Promise<Response | null>;
  readonly now?: () => Date;
};

/** POST /api/devices/iroh/enrollment-tokens (authenticated, native bearer). */
export async function handleIrohEnrollmentTokenMint(
  request: Request,
  dependencies: IrohEnrollmentDependencies = {},
): Promise<Response> {
  const verify = dependencies.verify ?? verifyRequest;
  let user: Awaited<ReturnType<typeof verifyRequest>>;
  try {
    user = await verify(request, { allowCookie: false });
  } catch {
    return jsonResponse({ error: "unauthorized" }, 401);
  }
  if (!user) return unauthorized();

  const mutationForbidden = enforceBrowserMutationProtection(request);
  if (mutationForbidden) return mutationForbidden;

  const body = await readOptionalEmptyJsonObject(request);
  if (!body.ok) return body.response;

  const now = (dependencies.now ?? (() => new Date()))();
  const token = randomBytes(IROH_ENROLLMENT_TOKEN_BYTES).toString("base64url");
  const expiresAt = new Date(now.getTime() + IROH_ENROLLMENT_TOKEN_LIFETIME_MS);
  try {
    await (dependencies.store ?? drizzleIrohEnrollmentStore()).mintToken({
      userId: user.id,
      tokenHash: sha256(token),
      now,
      expiresAt,
    });
  } catch (error) {
    return irohErrorResponse(error, "enrollment_token_mint");
  }
  return irohJson({ token, expires_at: expiresAt.toISOString() }, 201);
}

/**
 * POST /api/devices/iroh/enroll (unauthenticated: the caller is a headless
 * container that only holds the one-use provisioning token).
 */
export async function handleIrohEnrollment(
  request: Request,
  dependencies: IrohEnrollmentDependencies = {},
): Promise<Response> {
  const throttled = await (dependencies.rateLimit ?? enrollmentFirewallRateLimit)(request);
  if (throttled) return throttled;

  const body = await readRequiredJsonObject(request);
  if (!body.ok) return body.response;
  const record = body.value;
  if (Object.keys(record).some((key) => key !== "token")) {
    return jsonResponse({ error: "unknown_field" }, 400);
  }
  const token = record.token;
  // One uniform failure for every unusable token (malformed, unknown, already
  // consumed, expired) so the response never distinguishes them.
  if (
    typeof token !== "string" ||
    token.length > MAX_TOKEN_FIELD_LENGTH ||
    !ENROLLMENT_TOKEN_PATTERN.test(token)
  ) {
    return invalidEnrollmentToken();
  }

  const now = (dependencies.now ?? (() => new Date()))();
  try {
    const consumed = await (dependencies.store ?? drizzleIrohEnrollmentStore()).consumeToken({
      tokenHash: sha256(token),
      now,
    });
    if (!consumed) return invalidEnrollmentToken();
    const sessionTokens = await (dependencies.mintSession ?? mintStackSession)(consumed.userId);
    if (!sessionTokens) return invalidEnrollmentToken();
    return irohJson({
      accessToken: sessionTokens.accessToken,
      refreshToken: sessionTokens.refreshToken,
    }, 201);
  } catch (error) {
    return irohErrorResponse(error, "enrollment_exchange");
  }
}

export function drizzleIrohEnrollmentStore(): IrohEnrollmentStoreShape {
  return {
    mintToken: async (input) => {
      const db = cloudDb();
      await db.transaction(async (tx) => {
        await assertIrohUserMutationAllowed(tx, input.userId);
        await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`iroh:enrollment:${input.userId}`}, 0))`);
        // Opportunistic per-user GC: rows dead for over an hour carry no
        // audit value and would otherwise linger for deleted provisioning runs.
        const gcCutoff = new Date(input.now.getTime() - EXPIRED_TOKEN_GC_AGE_MS);
        await tx
          .delete(irohEnrollmentTokens)
          .where(and(
            eq(irohEnrollmentTokens.userId, input.userId),
            lte(irohEnrollmentTokens.expiresAt, gcCutoff),
          ));
        const outstandingWhere = and(
          eq(irohEnrollmentTokens.userId, input.userId),
          isNull(irohEnrollmentTokens.consumedAt),
          gt(irohEnrollmentTokens.expiresAt, input.now),
        );
        const [outstanding] = await tx
          .select({ value: count() })
          .from(irohEnrollmentTokens)
          .where(outstandingWhere);
        if ((outstanding?.value ?? 0) >= IROH_ENROLLMENT_MAX_OUTSTANDING_TOKENS) {
          const [oldest] = await tx
            .select({ expiresAt: irohEnrollmentTokens.expiresAt })
            .from(irohEnrollmentTokens)
            .where(outstandingWhere)
            .orderBy(asc(irohEnrollmentTokens.expiresAt))
            .limit(1);
          const retryAfterSeconds = Math.max(1, Math.ceil(
            ((oldest?.expiresAt ?? input.expiresAt).getTime() - input.now.getTime()) / 1_000,
          ));
          throw new IrohQuotaExceededError({
            code: "enrollment_token_quota",
            retryAfterSeconds,
          });
        }
        await tx.insert(irohEnrollmentTokens).values({
          userId: input.userId,
          tokenHash: input.tokenHash,
          createdAt: input.now,
          expiresAt: input.expiresAt,
        });
      });
    },

    consumeToken: async (input) => {
      try {
        return await cloudDb().transaction(async (tx) => {
          const [consumed] = await tx
            .update(irohEnrollmentTokens)
            .set({ consumedAt: input.now })
            .where(and(
              eq(irohEnrollmentTokens.tokenHash, input.tokenHash),
              isNull(irohEnrollmentTokens.consumedAt),
              gt(irohEnrollmentTokens.expiresAt, input.now),
            ))
            .returning({ userId: irohEnrollmentTokens.userId });
          if (!consumed) return null;
          // Account-deletion fence, same as mintToken: a token minted before
          // deletion must not redeem a Stack session once deletion is
          // pending. Throwing aborts the transaction, so the conditional
          // consume above also rolls back.
          await assertIrohUserMutationAllowed(tx, consumed.userId);
          return consumed;
        });
      } catch (error) {
        // The exchange route is unauthenticated: a fenced account must
        // answer exactly like an unknown, spent, or expired token.
        if (
          error instanceof IrohConflictError &&
          error.code === "account_deletion_in_progress"
        ) {
          return null;
        }
        throw error;
      }
    },
  };
}

/**
 * Mints a real Stack session for the enrolled user, mirroring the vault CLI
 * device-flow precedent (app/api/vault/cli/auth/poll). Tokens are returned
 * once and never persisted server-side.
 */
async function mintStackSession(userId: string): Promise<IrohEnrollmentSessionTokens | null> {
  const user = await getStackServerApp().getUser(userId);
  if (!user) return null;
  const session = await user.createSession({
    expiresInMillis: IROH_ENROLLMENT_SESSION_LIFETIME_MS,
  });
  const tokens = await session.getTokens();
  if (!tokens.accessToken || !tokens.refreshToken) return null;
  return { accessToken: tokens.accessToken, refreshToken: tokens.refreshToken };
}

/**
 * Per-IP throttle through the platform firewall, same pattern as the other
 * unauthenticated POST endpoints (vault CLI auth start, waitlist, feedback).
 * Only active on Vercel with the optional Iroh rule configured; the one-use
 * token itself remains the primary control.
 */
async function enrollmentFirewallRateLimit(request: Request): Promise<Response | null> {
  if (process.env.VERCEL !== "1" || !env.CMUX_IROH_RATE_LIMIT_ID) return null;
  const { error, rateLimited } = await checkRateLimit(env.CMUX_IROH_RATE_LIMIT_ID, { request });
  if (rateLimited || error === "blocked") {
    return jsonResponse({ error: "throttled" }, 429);
  }
  return null;
}

function invalidEnrollmentToken(): Response {
  return irohJson({ error: "invalid_enrollment_token" }, 404);
}

function irohJson(value: unknown, status: number): Response {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });
}

type BodyResult<T> =
  | { readonly ok: true; readonly value: T }
  | { readonly ok: false; readonly response: Response };

/**
 * The mint route takes no parameters: accept a missing body, an empty body,
 * or an empty JSON object, and reject anything carrying unknown content.
 */
async function readOptionalEmptyJsonObject(
  request: Request,
): Promise<BodyResult<Record<string, never>>> {
  const text = await readBoundedText(request);
  if (!text.ok) return text;
  if (text.value.trim().length === 0) return { ok: true, value: {} };
  let parsed: unknown;
  try {
    parsed = JSON.parse(text.value);
  } catch {
    return { ok: false, response: jsonResponse({ error: "invalid_json" }, 400) };
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    return { ok: false, response: jsonResponse({ error: "invalid_json" }, 400) };
  }
  if (Object.keys(parsed).length > 0) {
    return { ok: false, response: jsonResponse({ error: "unknown_field" }, 400) };
  }
  return { ok: true, value: {} };
}

async function readRequiredJsonObject(
  request: Request,
): Promise<BodyResult<Record<string, unknown>>> {
  if (request.headers.get("content-type")?.split(";", 1)[0]?.trim().toLowerCase() !== "application/json") {
    return { ok: false, response: jsonResponse({ error: "unsupported_media_type" }, 415) };
  }
  const text = await readBoundedText(request);
  if (!text.ok) return text;
  if (text.value.length === 0) {
    return { ok: false, response: jsonResponse({ error: "missing_body" }, 400) };
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(text.value);
  } catch {
    return { ok: false, response: jsonResponse({ error: "invalid_json" }, 400) };
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    return { ok: false, response: jsonResponse({ error: "invalid_json" }, 400) };
  }
  return { ok: true, value: parsed as Record<string, unknown> };
}

async function readBoundedText(request: Request): Promise<BodyResult<string>> {
  const contentLength = request.headers.get("content-length");
  if (contentLength) {
    const parsed = Number(contentLength);
    if (!Number.isSafeInteger(parsed) || parsed < 0 || parsed > MAX_BODY_BYTES) {
      return { ok: false, response: jsonResponse({ error: "request_too_large" }, 413) };
    }
  }
  const reader = request.body?.getReader();
  if (!reader) return { ok: true, value: "" };
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    while (true) {
      const next = await reader.read();
      if (next.done) break;
      total += next.value.byteLength;
      if (total > MAX_BODY_BYTES) {
        await reader.cancel();
        return { ok: false, response: jsonResponse({ error: "request_too_large" }, 413) };
      }
      chunks.push(next.value);
    }
  } catch {
    return { ok: false, response: jsonResponse({ error: "invalid_body" }, 400) };
  }
  return {
    ok: true,
    value: Buffer.concat(chunks.map((chunk) => Buffer.from(chunk)), total).toString("utf8"),
  };
}
