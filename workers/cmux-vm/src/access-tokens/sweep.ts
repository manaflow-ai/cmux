import { Clock, Effect } from "effect";
import { AccessTokenStore } from "./tokens.ts";
import { UpstreamAccessTokens } from "../upstream/access-tokens.ts";

/** Scheduled cleanup: revoke provider identities whose cmux token expired or was revoked. */
export const sweepExpiredAccessTokenIdentities =
  Effect.gen(function* () {
    const store = yield* AccessTokenStore;
    const upstream = yield* UpstreamAccessTokens;
    const now = new Date(yield* Clock.currentTimeMillis);
    const records = yield* store.listProviderIdentities(now);
    const pending = records.flatMap((record) => record.providerIdentityId !== null ? [{ identityId: record.providerIdentityId }] : []);
    yield* Effect.forEach(
      pending,
      (record) => {
        const found = records.find((candidate) => candidate.providerIdentityId === record.identityId);
        return found === undefined
          ? Effect.void
          : upstream.revokeIdentity(record.identityId).pipe(Effect.zipRight(store.clearProviderIdentity(found.tenantId, found.id, record.identityId)), Effect.ignore);
      },
      { concurrency: 8 },
    );
  });
