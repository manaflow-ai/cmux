/**
 * The shared cache of Stack team-membership answers (mesh M4, cx-0op.7).
 *
 * Only a positive answer ("is a member") is cached, for 60 s; "not a member"
 * is never cached, so a user added to a team works on the next call. The cache
 * is shared by every Worker isolate (a Postgres table in production), so the
 * Stack team-membership webhook can revoke an entry for all of them at once
 * (G1, cx-0op.6).
 *
 * Ordering rule: an answer is stored with the time its Stack request was SENT
 * (`askedAt`), and is never valid when a revocation at or after that time is
 * recorded. So a "member" answer that was in flight when the webhook revoked
 * the user can neither be stored nor be read afterwards.
 */
import { Context, Effect, Layer } from "effect";
import type { StoreError } from "../db/sql.ts";
import type { TenantId, UserId } from "../lib/ids.ts";

/** How long a positive answer is trusted. */
export const MEMBERSHIP_POSITIVE_TTL_MS = 60 * 1000;

export interface MembershipCacheService {
  /** Whether a positive answer asked after `since`, and after the last revocation, is held. */
  readonly fresh: (tenantId: TenantId, userId: UserId, since: Date) => Effect.Effect<boolean, StoreError>;
  /** Stores a positive answer whose Stack request was sent at `askedAt`; a no-op when a revocation at or after `askedAt` is recorded. */
  readonly rememberMember: (tenantId: TenantId, userId: UserId, askedAt: Date) => Effect.Effect<void, StoreError>;
  /** Drops the positive answer and records the revocation: no answer asked at or before `at` is valid again. */
  readonly revoke: (tenantId: TenantId, userId: UserId, at: Date) => Effect.Effect<void, StoreError>;
  /** `revoke` in every tenant that holds an entry for the user (Stack `user.deleted`). */
  readonly revokeUser: (userId: UserId, at: Date) => Effect.Effect<void, StoreError>;
}

export class MembershipCache extends Context.Tag("cmux-vm/MembershipCache")<MembershipCache, MembershipCacheService>() {}

/** The same rules in memory: tests, the live proof server, and `wrangler dev`. */
export function makeMemoryMembershipCache() {
  const rows = new Map<string, { askedAt: Date | null; revokedAt: Date | null }>();
  const keyOf = (tenantId: string, userId: string) => `${tenantId}\u0000${userId}`;
  const service: MembershipCacheService = {
    fresh: (tenantId, userId, since) =>
      Effect.sync(() => {
        const row = rows.get(keyOf(tenantId, userId));
        if (row === undefined || row.askedAt === null || row.askedAt <= since) return false;
        return row.revokedAt === null || row.askedAt > row.revokedAt;
      }),
    rememberMember: (tenantId, userId, askedAt) =>
      Effect.sync(() => {
        const key = keyOf(tenantId, userId);
        const row = rows.get(key) ?? { askedAt: null, revokedAt: null };
        if (row.revokedAt !== null && askedAt <= row.revokedAt) return;
        if (row.askedAt === null || askedAt > row.askedAt) row.askedAt = askedAt;
        rows.set(key, row);
      }),
    revoke: (tenantId, userId, at) =>
      Effect.sync(() => {
        const key = keyOf(tenantId, userId);
        const row = rows.get(key) ?? { askedAt: null, revokedAt: null };
        if (row.revokedAt === null || at > row.revokedAt) row.revokedAt = at;
        rows.set(key, row);
      }),
    revokeUser: (userId, at) =>
      Effect.sync(() => {
        for (const [key, row] of rows) {
          if (!key.endsWith(`\u0000${userId}`)) continue;
          if (row.revokedAt === null || at > row.revokedAt) row.revokedAt = at;
        }
      }),
  };
  return { service, layer: Layer.succeed(MembershipCache, service), rows };
}
