import { Clock, Effect } from "effect";
import { AccessTokenStore } from "./tokens.ts";
import { UpstreamAccessTokens } from "../upstream/access-tokens.ts";
import type { TenantId } from "../lib/ids.ts";

/** Wave 2 cron hook: revoke provider identities whose cmux token expired. */
export const sweepExpiredAccessTokenIdentities = (tenantId: TenantId) =>
  Effect.gen(function* () {
    const store = yield* AccessTokenStore;
    const upstream = yield* UpstreamAccessTokens;
    const now = new Date(yield* Clock.currentTimeMillis);
    const records = yield* store.list(tenantId, 1000);
    yield* Effect.forEach(
      records.filter((record) => record.expiresAt <= now && record.providerIdentityId !== null),
      (record) => upstream.revokeIdentity(record.providerIdentityId as string).pipe(Effect.ignore),
      { concurrency: 8 },
    );
  });
