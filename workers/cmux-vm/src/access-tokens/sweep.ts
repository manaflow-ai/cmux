import { Clock, Effect } from "effect";
import { AccessTokenStore, type AccessTokenRecord } from "./tokens.ts";
import { UpstreamAccessTokens } from "../upstream/access-tokens.ts";

export const revokeAccessTokenIdentity = (record: AccessTokenRecord, at: Date) =>
  Effect.gen(function* () {
    const store = yield* AccessTokenStore;
    yield* store.revoke(record.tenantId, record.id, at);
    if (record.providerIdentityId === null) return;
    const upstream = yield* UpstreamAccessTokens;
    yield* upstream.revokeIdentity(record.providerIdentityId);
    yield* store.clearProviderIdentity(record.tenantId, record.id, record.providerIdentityId);
  });

/** Scheduled cleanup: revoke provider identities whose cmux token expired or was revoked. */
export const sweepExpiredAccessTokenIdentities =
  Effect.gen(function* () {
    const store = yield* AccessTokenStore;
    const now = new Date(yield* Clock.currentTimeMillis);
    const records = yield* store.listProviderIdentities(now);
    yield* Effect.forEach(
      records,
      (record) => revokeAccessTokenIdentity(record, now).pipe(
        Effect.catchAll((error) => Effect.logWarning("cmux-vm access token identity cleanup failed").pipe(
          Effect.annotateLogs({ tokenId: record.id, tenantId: record.tenantId, operation: error.operation }),
        )),
      ),
      { concurrency: 8 },
    );
  });
