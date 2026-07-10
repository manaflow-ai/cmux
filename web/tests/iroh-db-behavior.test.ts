import { afterAll, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { randomUUID } from "node:crypto";
import * as Effect from "effect/Effect";
import postgres, { type Sql } from "postgres";
import { closeCloudDbForTests } from "../db/client";
import {
  accountDeletionAdvisoryLockKey,
  accountDeletionUserHash,
} from "../services/account/deletionLock";
import type { PairGrantPeer } from "../services/iroh/crypto";
import {
  IROH_RETENTION_BATCH_SIZE,
  IrohRepository,
  IrohRepositoryLive,
  type IrohRepositoryShape,
} from "../services/iroh/repository";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;
const NOW = new Date("2026-07-09T20:00:00.000Z");

let sql: Sql | null = null;
let repository: IrohRepositoryShape | null = null;

beforeAll(async () => {
  if (!runDbTests) return;
  const databaseURL = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
  if (!databaseURL) throw new Error("DATABASE_URL is required when CMUX_DB_TEST=1");
  sql = postgres(databaseURL, { max: 8 });
  repository = await Effect.runPromise(
    Effect.gen(function* () { return yield* IrohRepository; }).pipe(
      Effect.provide(IrohRepositoryLive),
    ),
  );
});

beforeEach(async () => {
  if (!sql) return;
  await sql`
    truncate
      iroh_relay_token_issuances,
      iroh_pair_grant_issuances,
      iroh_registration_challenges,
      iroh_endpoint_bindings,
      iroh_account_security_states,
      account_deletion_tombstones
    restart identity cascade
  `;
});

afterAll(async () => {
  await closeCloudDbForTests();
  await sql?.end();
});

describe("Iroh trust broker database behavior", () => {
  dbTest("blocks new trust state once account deletion wins the account fence", async () => {
    const userId = "user-deleting";
    let mutation: ReturnType<typeof Effect.runPromiseExit> | undefined;
    await requiredSql().begin(async (deletionSql) => {
      await deletionSql`
        select pg_advisory_xact_lock(
          hashtextextended(${accountDeletionAdvisoryLockKey(userId)}, 0)
        )
      `;
      await deletionSql`
        insert into account_deletion_tombstones (user_id_hash, user_id, status, updated_at)
        values (${accountDeletionUserHash(userId)}, ${userId}, 'pending', now())
      `;
      mutation = Effect.runPromiseExit(requiredRepository().issueChallenge({
        userId,
        deviceUuid: randomUUID(),
        appInstanceId: randomUUID(),
        tag: "stable",
        endpointId: "09".repeat(32),
        identityGeneration: 1,
        payloadSha256: "08".repeat(32),
        nonceHash: "07".repeat(32),
        now: NOW,
        expiresAt: new Date(NOW.getTime() + 5 * 60 * 1_000),
      }));
      await waitForAdvisoryLockWaiter();
    });

    if (!mutation) throw new Error("mutation was not started");
    const exit = await mutation;

    expect(exit._tag).toBe("Failure");
    expect(String(exit)).toContain("account_deletion_in_progress");
    const [{ total }] = await requiredSql()<Array<{ total: string }>>`
      select count(*)::text as total from iroh_registration_challenges where user_id = ${userId}
    `;
    expect(total).toBe("0");
  });

  dbTest("lets an earlier trust transaction finish before deletion removes it", async () => {
    const userId = "user-mutation-first";
    let deletion: Promise<unknown> | undefined;
    await requiredSql().begin(async (mutationSql) => {
      await mutationSql`
        select pg_advisory_xact_lock(
          hashtextextended(${accountDeletionAdvisoryLockKey(userId)}, 0)
        )
      `;
      await mutationSql`
        insert into iroh_registration_challenges (
          user_id, device_uuid, app_instance_id, tag, endpoint_id,
          identity_generation, payload_sha256, nonce_hash, created_at, expires_at
        ) values (
          ${userId}, ${randomUUID()}, ${randomUUID()}, 'stable', ${"0a".repeat(32)},
          1, ${"0b".repeat(32)}, ${"0c".repeat(32)}, now(), now() + interval '5 minutes'
        )
      `;
      deletion = requiredSql().begin(async (deletionSql) => {
        await deletionSql`
          select pg_advisory_xact_lock(
            hashtextextended(${accountDeletionAdvisoryLockKey(userId)}, 0)
          )
        `;
        await deletionSql`
          insert into account_deletion_tombstones (user_id_hash, user_id, status, updated_at)
          values (${accountDeletionUserHash(userId)}, ${userId}, 'pending', now())
        `;
        await deletionSql`delete from iroh_registration_challenges where user_id = ${userId}`;
      });
      await waitForAdvisoryLockWaiter();
      const [{ total }] = await mutationSql<Array<{ total: string }>>`
        select count(*)::text as total
        from iroh_registration_challenges
        where user_id = ${userId}
      `;
      expect(total).toBe("1");
    });
    if (!deletion) throw new Error("deletion was not started");
    await deletion;
    const [{ total }] = await requiredSql()<Array<{ total: string }>>`
      select count(*)::text as total
      from iroh_registration_challenges
      where user_id = ${userId}
    `;
    expect(total).toBe("0");
  });

  dbTest("fences binding authorization, grants, relay completion, and cleanup during deletion", async () => {
    const userId = "user-deletion-fences";
    const iosId = await insertBinding({
      userId,
      platform: "ios",
      endpointId: "0d".repeat(32),
    });
    const macId = await insertBinding({
      userId,
      platform: "mac",
      endpointId: "0e".repeat(32),
    });
    const ios = await pairPeer(iosId);
    const mac = await pairPeer(macId);
    const [issuance] = await requiredSql()<Array<{ id: string }>>`
      insert into iroh_relay_token_issuances (
        user_id, binding_id, endpoint_id_hash, status, requested_at
      ) values (${userId}, ${macId}, ${"0f".repeat(32)}, 'pending', ${NOW})
      returning id::text
    `;
    if (!issuance) throw new Error("issuance insert failed");
    await requiredSql()`
      insert into account_deletion_tombstones (user_id_hash, user_id, status, updated_at)
      values (${accountDeletionUserHash(userId)}, ${userId}, 'pending', now())
    `;

    const repository = requiredRepository();
    const operations: Array<Effect.Effect<unknown, unknown>> = [
      repository.findActiveBindings(userId, [iosId, macId]),
      repository.revokeBinding({ userId, bindingId: macId, now: NOW }),
      repository.accountLanGeneration({ userId, now: NOW }),
      repository.pruneExpiredState({ userId, now: NOW }),
      repository.recordPairGrant({
        userId,
        jti: randomUUID(),
        initiator: ios,
        acceptor: mac,
        signingKeyId: "current",
        alpn: "cmux/mobile/1",
        scope: "cmux.mobile.attach",
        issuedAt: NOW,
        notBefore: NOW,
        expiresAt: new Date(NOW.getTime() + 7 * 24 * 60 * 60 * 1_000),
      }),
      repository.reserveRelayIssuance({ userId, bindingId: macId, now: NOW }),
      repository.completeRelayIssuance({
        userId,
        issuanceId: issuance.id,
        bindingId: macId,
        endpointId: mac.endpointId,
        tokenHash: "10".repeat(32),
        completedAt: NOW,
        expiresAt: new Date(NOW.getTime() + 24 * 60 * 60 * 1_000),
      }),
      repository.failRelayIssuance({
        userId,
        issuanceId: issuance.id,
        completedAt: NOW,
        failureCode: "test_failure",
      }),
    ];
    for (const operation of operations) {
      const exit = await Effect.runPromiseExit(operation);
      expect(exit._tag).toBe("Failure");
      expect(String(exit)).toContain("account_deletion_in_progress");
    }
    const [state] = await requiredSql()<Array<{
      revoked: boolean;
      grants: string;
      issuanceStatus: string;
      securityStates: string;
    }>>`
      select
        exists(select 1 from iroh_endpoint_bindings where id = ${macId} and revoked_at is not null) as revoked,
        (select count(*)::text from iroh_pair_grant_issuances where user_id = ${userId}) as grants,
        (select status from iroh_relay_token_issuances where id = ${issuance.id}) as "issuanceStatus",
        (select count(*)::text from iroh_account_security_states where user_id = ${userId}) as "securityStates"
    `;
    expect(state).toEqual({
      revoked: false,
      grants: "0",
      issuanceStatus: "pending",
      securityStates: "0",
    });
  });

  dbTest("atomically consumes a challenge exactly once under concurrency", async () => {
    const repo = requiredRepository();
    const deviceId = randomUUID();
    const appInstanceId = randomUUID();
    const endpointId = "10".repeat(32);
    const nonceHash = "20".repeat(32);
    const pathHintExpiry = new Date(NOW.getTime() + 30 * 60 * 1_000);
    const challenge = await Effect.runPromise(repo.issueChallenge({
      userId: "user-registration",
      deviceUuid: deviceId,
      appInstanceId,
      tag: "stable",
      endpointId,
      identityGeneration: 1,
      payloadSha256: "30".repeat(32),
      nonceHash,
      now: NOW,
      expiresAt: new Date(NOW.getTime() + 5 * 60 * 1_000),
    }));
    const register = () => Effect.runPromise(repo.consumeChallengeAndRegister({
      userId: "user-registration",
      challengeId: challenge.id,
      nonceHash,
      payload: {
        route_contract_version: 1,
        deviceId,
        appInstanceId,
        tag: "stable",
        platform: "mac",
        endpointId,
        identityGeneration: 1,
        pairingEnabled: true,
        capabilities: [],
        pathHints: [{
          kind: "direct_address",
          value: "10.0.0.20:4433",
          source: "lan",
          privacy_scope: "local_network",
          observed_at: new Date(NOW.getTime() - 5 * 60 * 1_000).toISOString(),
          expires_at: pathHintExpiry.toISOString(),
          network_profile: { source: "lan", profile_id: "local" },
        }],
      },
      now: NOW,
      deviceLimitOverrideAllowed: false,
    }));
    const results = await Promise.allSettled([register(), register()]);
    expect(results.filter((result) => result.status === "fulfilled")).toHaveLength(1);
    expect(results.filter((result) => result.status === "rejected")).toHaveLength(1);
    const [{ bindings, consumed, nextExpiry }] = await requiredSql()<Array<{
      bindings: string;
      consumed: string;
      nextExpiry: Date | null;
    }>>`
      select
        (select count(*)::text from iroh_endpoint_bindings) as bindings,
        (select count(*)::text from iroh_registration_challenges where consumed_at is not null) as consumed,
        (select path_hints_next_expiry from iroh_endpoint_bindings limit 1) as "nextExpiry"
    `;
    expect({ bindings, consumed }).toEqual({ bindings: "1", consumed: "1" });
    expect(nextExpiry?.getTime()).toBe(pathHintExpiry.getTime());
  });

  dbTest("enforces globally unique active EndpointIDs and app instances", async () => {
    const appInstanceId = randomUUID();
    const endpointId = "40".repeat(32);
    await insertBinding({ userId: "user-a", appInstanceId, endpointId });
    await expectPostgresError(insertBinding({ userId: "user-b", endpointId }), "23505");
    await expectPostgresError(insertBinding({ userId: "user-b", appInstanceId, endpointId: "41".repeat(32) }), "23505");
    await expectPostgresError(insertBinding({ userId: "user-a", endpointId: "not-an-endpoint" }), "23514");
    await expectPostgresError(requiredSql()`
      insert into iroh_endpoint_bindings (
        user_id, device_uuid, app_instance_id, tag, platform, endpoint_id, identity_generation
      ) values (
        'user-a', ${randomUUID()}, ${randomUUID()}, 'stable', 'linux', ${"42".repeat(32)}, 1
      )
    `, "23514");
    await expectPostgresError(requiredSql()`
      insert into iroh_endpoint_bindings (
        user_id, device_uuid, app_instance_id, tag, platform, endpoint_id, identity_generation
      ) values (
        'user-a', ${randomUUID()}, ${randomUUID()}, 'stable', 'mac', ${"43".repeat(32)}, 2147483648
      )
    `, "22003");
  });

  dbTest("serializes the pair-grant hourly quota", async () => {
    const repo = requiredRepository();
    const initiatorId = await insertBinding({ userId: "user-pair", platform: "ios", endpointId: "50".repeat(32) });
    const acceptorId = await insertBinding({ userId: "user-pair", platform: "mac", endpointId: "51".repeat(32) });
    for (let index = 0; index < 59; index += 1) {
      await requiredSql()`
        insert into iroh_pair_grant_issuances (
          user_id, jti, initiator_binding_id, acceptor_binding_id, signing_key_id,
          alpn, scope, issued_at, not_before, expires_at
        ) values (
          'user-pair', ${randomUUID()}, ${initiatorId}, ${acceptorId}, 'current',
          'cmux/mobile/1', 'cmux.mobile.attach',
          ${new Date(NOW.getTime() - index * 1_000)},
          ${new Date(NOW.getTime() - index * 1_000)},
          ${new Date(NOW.getTime() + 7 * 24 * 60 * 60 * 1_000)}
        )
      `;
    }
    const initiator = await pairPeer(initiatorId);
    const acceptor = await pairPeer(acceptorId);
    const reserve = () => Effect.runPromise(repo.recordPairGrant({
      userId: "user-pair",
      jti: randomUUID(),
      initiator,
      acceptor,
      signingKeyId: "current",
      alpn: "cmux/mobile/1",
      scope: "cmux.mobile.attach",
      issuedAt: NOW,
      notBefore: NOW,
      expiresAt: new Date(NOW.getTime() + 7 * 24 * 60 * 60 * 1_000),
    }));
    const results = await Promise.allSettled([reserve(), reserve()]);
    expect(results.filter((result) => result.status === "fulfilled")).toHaveLength(1);
    expect(results.filter((result) => result.status === "rejected")).toHaveLength(1);
    const [{ total }] = await requiredSql()<Array<{ total: string }>>`
      select count(*)::text as total from iroh_pair_grant_issuances where user_id = 'user-pair'
    `;
    expect(total).toBe("60");
  });

  dbTest("revalidates pairability and exact signed peers inside the grant transaction", async () => {
    const initiatorId = await insertBinding({
      userId: "user-pair-race",
      platform: "ios",
      endpointId: "52".repeat(32),
    });
    const acceptorId = await insertBinding({
      userId: "user-pair-race",
      platform: "mac",
      endpointId: "53".repeat(32),
    });
    const initiator = await pairPeer(initiatorId);
    const acceptor = await pairPeer(acceptorId);
    await requiredSql()`
      update iroh_endpoint_bindings
      set pairing_enabled = false
      where id = ${acceptorId}
    `;
    const exit = await Effect.runPromiseExit(requiredRepository().recordPairGrant({
      userId: "user-pair-race",
      jti: randomUUID(),
      initiator,
      acceptor,
      signingKeyId: "current",
      alpn: "cmux/mobile/1",
      scope: "cmux.mobile.attach",
      issuedAt: NOW,
      notBefore: NOW,
      expiresAt: new Date(NOW.getTime() + 7 * 24 * 60 * 60 * 1_000),
    }));
    expect(exit._tag).toBe("Failure");
    const [{ total }] = await requiredSql()<Array<{ total: string }>>`
      select count(*)::text as total
      from iroh_pair_grant_issuances
      where user_id = 'user-pair-race'
    `;
    expect(total).toBe("0");
  });

  dbTest("serializes relay quota reservations before provider work", async () => {
    const repo = requiredRepository();
    const bindingId = await insertBinding({ userId: "user-relay", endpointId: "60".repeat(32) });
    for (let index = 0; index < 2; index += 1) {
      await requiredSql()`
        insert into iroh_relay_token_issuances (
          user_id, binding_id, endpoint_id_hash, status, requested_at
        ) values (
          'user-relay', ${bindingId}, ${"70".repeat(32)}, 'failed',
          ${new Date(NOW.getTime() - index * 1_000)}
        )
      `;
    }
    const reserve = () => Effect.runPromise(repo.reserveRelayIssuance({
      userId: "user-relay",
      bindingId,
      now: NOW,
    }));
    const results = await Promise.allSettled([reserve(), reserve()]);
    expect(results.filter((result) => result.status === "fulfilled")).toHaveLength(1);
    expect(results.filter((result) => result.status === "rejected")).toHaveLength(1);
    const [{ total }] = await requiredSql()<Array<{ total: string }>>`
      select count(*)::text as total from iroh_relay_token_issuances where binding_id = ${bindingId}
    `;
    expect(total).toBe("3");
  });

  dbTest("fails relay finalization when revocation commits during provider mint", async () => {
    const repo = requiredRepository();
    const endpointId = "61".repeat(32);
    const bindingId = await insertBinding({ userId: "user-relay-race", endpointId });
    const reservation = await Effect.runPromise(repo.reserveRelayIssuance({
      userId: "user-relay-race",
      bindingId,
      now: NOW,
    }));
    expect(await Effect.runPromise(repo.revokeBinding({
      userId: "user-relay-race",
      bindingId,
      now: new Date(NOW.getTime() + 1_000),
    }))).toBe(true);
    expect(await Effect.runPromise(repo.completeRelayIssuance({
      userId: "user-relay-race",
      issuanceId: reservation.issuanceId,
      bindingId,
      endpointId,
      tokenHash: "62".repeat(32),
      completedAt: new Date(NOW.getTime() + 2_000),
      expiresAt: new Date(NOW.getTime() + 24 * 60 * 60 * 1_000),
    }))).toBe(false);
    const [issuance] = await requiredSql()<Array<{ status: string; failureCode: string | null }>>`
      select status, failure_code as "failureCode"
      from iroh_relay_token_issuances
      where id = ${reservation.issuanceId}
    `;
    expect(issuance).toEqual({
      status: "failed",
      failureCode: "binding_inactive_after_mint",
    });
  });

  dbTest("global retention clears revoked hints and expired private data from Aurora", async () => {
    const repo = requiredRepository();
    const activeId = await insertBinding({
      userId: "user-retention",
      endpointId: "80".repeat(32),
      pathHints: [
        storedLanHint("10.0.0.1:4433", "2026-07-09T18:55:00.000Z", "2026-07-09T19:00:00.000Z"),
        storedLanHint("10.0.0.2:4433", "2026-07-09T19:55:00.000Z", "2026-07-09T20:30:00.000Z"),
      ],
    });
    const revokedId = await insertBinding({
      userId: "user-retention",
      endpointId: "81".repeat(32),
      pathHints: [storedLanHint("10.0.0.3:4433", "2026-07-09T19:55:00.000Z", "2026-07-09T20:30:00.000Z")],
    });
    const untouchedId = await insertBinding({
      userId: "user-retention",
      endpointId: "82".repeat(32),
      pathHints: [storedLanHint("10.0.0.4:4433", "2026-07-09T19:55:00.000Z", "2026-07-09T20:30:00.000Z")],
    });
    const oldRevokedId = await insertBinding({
      userId: "user-retention",
      endpointId: "83".repeat(32),
    });
    await requiredSql()`
      update iroh_endpoint_bindings
      set revoked_at = ${new Date(NOW.getTime() - 31 * 24 * 60 * 60 * 1_000)}
      where id = ${oldRevokedId}
    `;
    const [untouchedBefore] = await requiredSql()<Array<{ updatedAt: Date }>>`
      select updated_at as "updatedAt" from iroh_endpoint_bindings where id = ${untouchedId}
    `;
    await requiredSql()`
      insert into iroh_pair_grant_issuances (
        user_id, jti, initiator_binding_id, acceptor_binding_id, signing_key_id,
        alpn, scope, issued_at, not_before, expires_at
      ) values (
        'user-retention', ${randomUUID()}, ${activeId}, ${revokedId}, 'current',
        'cmux/mobile/1', 'cmux.mobile.attach', ${NOW}, ${NOW}, ${new Date(NOW.getTime() + 1_000)}
      )
    `;
    await Effect.runPromise(repo.revokeBinding({ userId: "user-retention", bindingId: revokedId, now: NOW }));
    await Effect.runPromise(repo.pruneExpiredStateGlobally({ now: NOW }));
    const rows = await requiredSql()<Array<{ id: string; pathHints: unknown[] }>>`
      select id::text, path_hints as "pathHints"
      from iroh_endpoint_bindings
      where id in (${activeId}, ${revokedId})
      order by id
    `;
    expect(rows.find((row) => row.id === activeId)?.pathHints).toHaveLength(1);
    expect(rows.find((row) => row.id === revokedId)?.pathHints).toEqual([]);
    const [grant] = await requiredSql()<Array<{ revokedAt: Date | null }>>`
      select revoked_at as "revokedAt" from iroh_pair_grant_issuances where acceptor_binding_id = ${revokedId}
    `;
    expect(grant?.revokedAt).not.toBeNull();
    const [retentionState] = await requiredSql()<Array<{ oldExists: boolean; untouchedUpdatedAt: Date }>>`
      select
        exists(select 1 from iroh_endpoint_bindings where id = ${oldRevokedId}) as "oldExists",
        (select updated_at from iroh_endpoint_bindings where id = ${untouchedId}) as "untouchedUpdatedAt"
    `;
    expect(retentionState?.oldExists).toBe(false);
    expect(retentionState?.untouchedUpdatedAt.getTime()).toBe(untouchedBefore?.updatedAt.getTime());
  });

  dbTest("retention skips locked hint rows and bounds each indexed batch", async () => {
    const lockedId = await insertBinding({
      userId: "user-retention-lock",
      endpointId: "84".repeat(32),
      pathHints: [storedLanHint("10.0.0.10:4433", "2026-07-09T18:55:00.000Z", "2026-07-09T19:00:00.000Z")],
    });
    const unlockedId = await insertBinding({
      userId: "user-retention-lock",
      endpointId: "85".repeat(32),
      pathHints: [storedLanHint("10.0.0.11:4433", "2026-07-09T18:55:00.000Z", "2026-07-09T19:00:00.000Z")],
    });
    await requiredSql().begin(async (lockingSql) => {
      await lockingSql`select id from iroh_endpoint_bindings where id = ${lockedId} for update`;
      await Effect.runPromise(requiredRepository().pruneExpiredStateGlobally({ now: NOW }));
      const rows = await lockingSql<Array<{ id: string; hints: number }>>`
        select id::text, jsonb_array_length(path_hints)::int as hints
        from iroh_endpoint_bindings
        where id in (${lockedId}, ${unlockedId})
      `;
      expect(rows.find((row) => row.id === lockedId)?.hints).toBe(1);
      expect(rows.find((row) => row.id === unlockedId)?.hints).toBe(0);
    });
    await Effect.runPromise(requiredRepository().pruneExpiredStateGlobally({ now: NOW }));
    const [locked] = await requiredSql()<Array<{ hints: number; nextExpiry: Date | null }>>`
      select
        jsonb_array_length(path_hints)::int as hints,
        path_hints_next_expiry as "nextExpiry"
      from iroh_endpoint_bindings
      where id = ${lockedId}
    `;
    expect(locked).toEqual({ hints: 0, nextExpiry: null });

    await requiredSql()`
      insert into iroh_registration_challenges (
        user_id, device_uuid, app_instance_id, tag, endpoint_id,
        identity_generation, payload_sha256, nonce_hash, created_at, expires_at
      )
      select
        'user-retention-batch', gen_random_uuid(), gen_random_uuid(), 'stable',
        repeat('86', 32), 1,
        md5('payload-a-' || value::text) || md5('payload-b-' || value::text),
        md5('nonce-a-' || value::text) || md5('nonce-b-' || value::text),
        ${new Date(NOW.getTime() - 3 * 24 * 60 * 60 * 1_000)},
        ${new Date(NOW.getTime() - 2 * 24 * 60 * 60 * 1_000)}
      from generate_series(1, ${IROH_RETENTION_BATCH_SIZE + 1}) as values(value)
    `;
    await Effect.runPromise(requiredRepository().pruneExpiredStateGlobally({ now: NOW }));
    const [{ remaining }] = await requiredSql()<Array<{ remaining: string }>>`
      select count(*)::text as remaining
      from iroh_registration_challenges
      where user_id = 'user-retention-batch'
    `;
    expect(remaining).toBe("1");

    await requiredSql()`
      insert into iroh_registration_challenges (
        user_id, device_uuid, app_instance_id, tag, endpoint_id,
        identity_generation, payload_sha256, nonce_hash, created_at, expires_at
      )
      select
        'user-retention-scoped', gen_random_uuid(), gen_random_uuid(), 'stable',
        repeat('87', 32), 1,
        md5('scoped-payload-a-' || value::text) || md5('scoped-payload-b-' || value::text),
        md5('scoped-nonce-a-' || value::text) || md5('scoped-nonce-b-' || value::text),
        ${new Date(NOW.getTime() - 3 * 24 * 60 * 60 * 1_000)},
        ${new Date(NOW.getTime() - 2 * 24 * 60 * 60 * 1_000)}
      from generate_series(1, ${IROH_RETENTION_BATCH_SIZE + 1}) as values(value)
    `;
    await Effect.runPromise(requiredRepository().pruneExpiredState({
      userId: "user-retention-scoped",
      now: NOW,
    }));
    const [{ scopedRemaining }] = await requiredSql()<Array<{ scopedRemaining: string }>>`
      select count(*)::text as "scopedRemaining"
      from iroh_registration_challenges
      where user_id = 'user-retention-scoped'
    `;
    expect(scopedRemaining).toBe("1");
  });

  dbTest("binding deletion cascades grant and relay audit rows", async () => {
    const bindingId = await insertBinding({ userId: "user-delete", endpointId: "90".repeat(32) });
    const peerId = await insertBinding({ userId: "user-delete", endpointId: "91".repeat(32) });
    await requiredSql()`
      insert into iroh_pair_grant_issuances (
        user_id, jti, initiator_binding_id, acceptor_binding_id, signing_key_id,
        alpn, scope, issued_at, not_before, expires_at
      ) values (
        'user-delete', ${randomUUID()}, ${bindingId}, ${peerId}, 'current',
        'cmux/mobile/1', 'cmux.mobile.attach', ${NOW}, ${NOW}, ${new Date(NOW.getTime() + 1_000)}
      )
    `;
    await requiredSql()`
      insert into iroh_relay_token_issuances (
        user_id, binding_id, endpoint_id_hash, status, requested_at
      ) values ('user-delete', ${bindingId}, ${"92".repeat(32)}, 'pending', ${NOW})
    `;
    await requiredSql()`delete from iroh_endpoint_bindings where id = ${bindingId}`;
    const [{ grants, relays }] = await requiredSql()<Array<{ grants: string; relays: string }>>`
      select
        (select count(*)::text from iroh_pair_grant_issuances) as grants,
        (select count(*)::text from iroh_relay_token_issuances) as relays
    `;
    expect({ grants, relays }).toEqual({ grants: "0", relays: "0" });
  });
});

async function insertBinding(input: {
  readonly userId: string;
  readonly appInstanceId?: string;
  readonly endpointId: string;
  readonly platform?: "mac" | "ios";
  readonly pathHints?: unknown[];
}): Promise<string> {
  const [row] = await requiredSql()<Array<{ id: string }>>`
    insert into iroh_endpoint_bindings (
      user_id, device_uuid, app_instance_id, tag, platform, endpoint_id,
      identity_generation, pairing_enabled, capabilities, path_hints,
      path_hints_next_expiry
    ) values (
      ${input.userId}, ${randomUUID()}, ${input.appInstanceId ?? randomUUID()}, 'stable',
      ${input.platform ?? "mac"}, ${input.endpointId}, 1, true, '[]'::jsonb,
      ${requiredSql().json((input.pathHints ?? []) as never)},
      ${earliestStoredHintExpiry(input.pathHints ?? [])}
    ) returning id::text
  `;
  if (!row) throw new Error("binding insert returned no row");
  return row.id;
}

async function pairPeer(bindingId: string): Promise<PairGrantPeer> {
  const [row] = await requiredSql()<Array<{
    bindingId: string;
    deviceId: string;
    tag: string;
    platform: "mac" | "ios";
    endpointId: string;
    identityGeneration: number;
  }>>`
    select
      id::text as "bindingId",
      device_uuid::text as "deviceId",
      tag,
      platform,
      endpoint_id as "endpointId",
      identity_generation as "identityGeneration"
    from iroh_endpoint_bindings
    where id = ${bindingId}
  `;
  if (!row) throw new Error("binding not found");
  return row;
}

function earliestStoredHintExpiry(pathHints: readonly unknown[]): Date | null {
  const expiries = pathHints.flatMap((hint) => {
    const value = (hint as { expires_at?: unknown } | null)?.expires_at;
    return typeof value === "string" ? [new Date(value).getTime()] : [];
  });
  return expiries.length > 0 ? new Date(Math.min(...expiries)) : null;
}

function requiredSql(): Sql {
  if (!sql) throw new Error("test database not initialized");
  return sql;
}

function requiredRepository(): IrohRepositoryShape {
  if (!repository) throw new Error("test repository not initialized");
  return repository;
}

function storedLanHint(value: string, observedAt: string, expiresAt: string): Record<string, unknown> {
  return {
    kind: "direct_address",
    value,
    source: "lan",
    privacy_scope: "local_network",
    observed_at: observedAt,
    expires_at: expiresAt,
    network_profile: { source: "lan", profile_id: "local" },
  };
}

async function expectPostgresError(promise: Promise<unknown>, expectedCode: string): Promise<void> {
  try {
    await promise;
  } catch (error) {
    expect((error as { code?: unknown }).code).toBe(expectedCode);
    return;
  }
  throw new Error(`expected Postgres error ${expectedCode}`);
}

async function waitForAdvisoryLockWaiter(): Promise<void> {
  for (let attempt = 0; attempt < 200; attempt += 1) {
    const [row] = await requiredSql()<Array<{ waiting: boolean }>>`
      select exists (
        select 1
        from pg_stat_activity
        where wait_event_type = 'Lock'
          and query ilike '%pg_advisory_xact_lock%'
      ) as waiting
    `;
    if (row?.waiting) return;
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  throw new Error("timed out waiting for the Iroh mutation to reach the account deletion fence");
}
