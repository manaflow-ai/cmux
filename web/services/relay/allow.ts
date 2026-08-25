// Backend half of the relay fleet's per-connection access-control hook.
// iroh-relay 1.0.3 (src/main.rs, `AccessConfig::Http`) POSTs once per
// connecting endpoint with NO body, the hex EndpointId in the `X-Iroh-NodeId`
// header, and an optional static `Authorization: Bearer <token>`. The relay
// proves key ownership in its handshake before calling, so the EndpointId is
// trustworthy; this side only decides whether that endpoint is admitted.

import { createHmac, timingSafeEqual } from "node:crypto";
import { and, eq, isNull, sql } from "drizzle-orm";

import { cloudDb } from "../../db/client";
import { irohEndpointBindings } from "../../db/schema";
import { hasBlockingAccountDeletionIdentity } from "../account/deletionLock";

export const RELAY_ALLOW_SIGNATURE_HEADER = "x-cmux-relay-allow-signature";

export type RelayAllowAdmission = "allow" | "deny";

/**
 * Same canonical-base64 rules as the iroh minter secret, but a missing or
 * malformed value returns null so the route can answer 503 (fail closed for
 * admissions of new endpoints) instead of throwing.
 */
export function parseRelayAllowSecret(value: string | undefined): Buffer | null {
  if (!value || value.length > 512) return null;
  const decoded = Buffer.from(value, "base64");
  const canonicalPadded = decoded.toString("base64");
  const canonicalUnpadded = canonicalPadded.replace(/=+$/, "");
  if (
    decoded.byteLength < 32 ||
    decoded.byteLength > 256 ||
    (value !== canonicalPadded && value !== canonicalUnpadded)
  ) {
    return null;
  }
  return decoded;
}

/** base64url HMAC-SHA256 over the raw request body bytes (empty body included). */
export function relayAllowSignature(secret: Buffer, body: Uint8Array): string {
  return createHmac("sha256", secret).update(body).digest("base64url");
}

export function verifyRelayAllowSignature(
  secret: Buffer,
  body: Uint8Array,
  provided: string,
): boolean {
  // 32 HMAC-SHA256 bytes are exactly 43 unpadded base64url characters.
  if (!/^[A-Za-z0-9_-]{43}$/.test(provided)) return false;
  const expected = createHmac("sha256", secret).update(body).digest();
  const candidate = Buffer.from(provided, "base64url");
  return candidate.byteLength === expected.byteLength &&
    timingSafeEqual(candidate, expected);
}

/**
 * Server-side execution bound for the admission queries. Postgres cancels a
 * query that exceeds it and returns the pooled connection, so a stalled
 * lookup cannot accumulate in-flight work while the route's own deadline
 * (slightly longer, see the route) bounds the response. Kept below that
 * deadline so the database usually cancels first and the route answers its
 * clean fail-closed 503 through the ordinary error path.
 */
export const RELAY_ALLOW_STATEMENT_TIMEOUT_MS = 2_500;

/**
 * Admitted iff the endpoint has an active (non-revoked) binding whose account
 * has no blocking deletion tombstone. The partial unique index
 * `iroh_endpoint_bindings_active_endpoint_unique` guarantees at most one
 * active binding per EndpointId across all accounts.
 */
export async function relayAllowAdmission(
  endpointId: string,
): Promise<RelayAllowAdmission> {
  const db = cloudDb();
  return await db.transaction(async (tx) => {
    // SET LOCAL via set_config: scoped to this transaction, cancels the
    // statement server-side on expiry (error 57014 -> the route's 503).
    await tx.execute(sql`
      select set_config(
        'statement_timeout',
        ${String(RELAY_ALLOW_STATEMENT_TIMEOUT_MS)},
        true
      )
    `);
    const [binding] = await tx
      .select({ userId: irohEndpointBindings.userId })
      .from(irohEndpointBindings)
      .where(and(
        eq(irohEndpointBindings.endpointId, endpointId),
        isNull(irohEndpointBindings.revokedAt),
      ))
      .limit(1);
    if (!binding) return "deny" as const;
    // Reads through the same transaction so the tombstone check shares this
    // transaction's statement_timeout.
    if (await hasBlockingAccountDeletionIdentity(tx, [binding.userId])) {
      return "deny" as const;
    }
    return "allow" as const;
  });
}
