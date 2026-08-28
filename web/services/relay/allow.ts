// Backend half of the relay fleet's per-connection access-control hook.
// iroh-relay 1.0.3 (src/main.rs, `AccessConfig::Http`) POSTs once per
// connecting endpoint with NO body, the hex EndpointId in the `X-Iroh-NodeId`
// header, and an optional static `Authorization: Bearer <token>`. The relay
// proves key ownership in its handshake before calling, so the EndpointId is
// trustworthy; this side only decides whether that endpoint is admitted.
//
// The admission lookup deliberately does NOT borrow the shared cloudDb
// client: it runs on the deadline-bounded per-hook client from ./hookDb, so
// every admission operation settles within a known bound and the concurrency
// slots — released strictly at settlement — bound retained work without ever
// staying saturated after an outage heals.

import { createHmac, timingSafeEqual } from "node:crypto";

import { isBlockingAccountDeletionTombstone } from "../account/deletionLock";
import { closeRelayHookDbClientForTests, relayHookDbClient } from "./hookDb";

export const RELAY_ALLOW_SIGNATURE_HEADER = "x-cmux-relay-allow-signature";

export type RelayAllowAdmission = "allow" | "deny";

/**
 * Hard cap on concurrently running admission lookups per runtime instance,
 * and the size of the dedicated admission pool. Cap == pool max means no
 * admission ever queues inside the driver; a saturated instance rejects
 * immediately (the route's fail-closed 503, which the relay treats as deny
 * and retries later). Slots release strictly when their operation settles,
 * and settlement is guaranteed by the phase deadlines below, so the cap is a
 * true bound on retained work AND the instance always recovers.
 */
export const RELAY_ALLOW_MAX_CONCURRENT_ADMISSIONS = 16;

/**
 * Server-side statement_timeout, set as a session parameter on every
 * admission connection: Postgres cancels an executing statement and frees
 * the connection.
 */
export const RELAY_ALLOW_STATEMENT_TIMEOUT_MS = 2_500;

/**
 * Client-side settle bound. postgres.js: a timer calls query.cancel(), which
 * rejects the query whether it is still queued or already executing. pg: the
 * pool's query_timeout enforces the same bound. Slightly above the statement
 * timeout so the server usually cancels first.
 */
export const RELAY_ALLOW_LOOKUP_SETTLE_MS = 4_000;

export class RelayAllowAdmissionSaturatedError extends Error {
  constructor() {
    super("relay allow admission concurrency saturated");
    this.name = "RelayAllowAdmissionSaturatedError";
  }
}

let inFlightAdmissions = 0;

/**
 * Runs one admission under the concurrency cap; rejects when saturated. The
 * slot is held until the operation settles — never released early — which is
 * safe because every admission operation is deadline-bounded at each phase
 * and therefore always settles.
 */
export async function withRelayAllowAdmissionSlot<T>(
  operation: () => Promise<T>,
): Promise<T> {
  if (inFlightAdmissions >= RELAY_ALLOW_MAX_CONCURRENT_ADMISSIONS) {
    throw new RelayAllowAdmissionSaturatedError();
  }
  inFlightAdmissions += 1;
  try {
    return await operation();
  } finally {
    inFlightAdmissions -= 1;
  }
}

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

type AdmissionRow = {
  readonly userId: string;
  readonly tombstoneStatus: string | null;
  readonly tombstoneUpdatedAt: Date | null;
  readonly tombstoneAnalyticsDeletedAt: Date | null;
};

// One round trip: the active binding plus its account's deletion tombstone.
// encode(sha256(convert_to(user_id, 'UTF8')), 'hex') is byte-for-byte
// accountDeletionUserHash from services/account/deletionLock.ts; the
// deletion-blocked case in tests/relay-allow-db-behavior.test.ts pins the
// equivalence against Postgres.
const ADMISSION_SQL = `
  select
    binding.user_id as "userId",
    tombstone.status as "tombstoneStatus",
    tombstone.updated_at as "tombstoneUpdatedAt",
    tombstone.analytics_deleted_at as "tombstoneAnalyticsDeletedAt"
  from iroh_endpoint_bindings binding
  left join account_deletion_tombstones tombstone
    on tombstone.user_id_hash = encode(sha256(convert_to(binding.user_id, 'UTF8')), 'hex')
  where binding.endpoint_id = $1
    and binding.revoked_at is null
  limit 1
`;

const ADMISSION_HOOK = "relay-allow";

async function admissionLookup(endpointId: string): Promise<AdmissionRow | null> {
  const client = relayHookDbClient(ADMISSION_HOOK, {
    maxConnections: RELAY_ALLOW_MAX_CONCURRENT_ADMISSIONS,
    statementTimeoutMs: RELAY_ALLOW_STATEMENT_TIMEOUT_MS,
    settleMs: RELAY_ALLOW_LOOKUP_SETTLE_MS,
  });
  const rows = await client.query(ADMISSION_SQL, [endpointId]);
  return (rows[0] as AdmissionRow | undefined) ?? null;
}

export async function closeRelayAllowAdmissionClientForTests(): Promise<void> {
  await closeRelayHookDbClientForTests(ADMISSION_HOOK);
}

/**
 * Admitted iff the endpoint has an active (non-revoked) binding whose account
 * has no blocking deletion tombstone. The partial unique index
 * `iroh_endpoint_bindings_active_endpoint_unique` guarantees at most one
 * active binding per EndpointId across all accounts.
 */
export async function relayAllowAdmission(
  endpointId: string,
): Promise<RelayAllowAdmission> {
  return await withRelayAllowAdmissionSlot(async () => {
    const row = await admissionLookup(endpointId);
    if (!row) return "deny" as const;
    if (tombstoneBlocks(row)) return "deny" as const;
    return "allow" as const;
  });
}

// Same blocking rule as hasBlockingAccountDeletionIdentity in
// services/account/deletionLock.ts, applied to the joined tombstone columns.
function tombstoneBlocks(row: AdmissionRow): boolean {
  if (row.tombstoneStatus === null) return false;
  if (row.tombstoneAnalyticsDeletedAt !== null) return true;
  return isBlockingAccountDeletionTombstone({
    status: row.tombstoneStatus,
    updatedAt: row.tombstoneUpdatedAt,
  });
}
