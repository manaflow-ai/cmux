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
import type { RelayCatalog } from "../services/relay/model";
import {
  RelayRepository,
  RelayRepositoryLive,
  type RelayRepositoryShape,
} from "../services/relay/repository";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;
const NOW = new Date("2026-07-09T20:00:00.000Z");

let sql: Sql | null = null;
let repository: IrohRepositoryShape | null = null;
let relayRepository: RelayRepositoryShape | null = null;

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
  relayRepository = await Effect.runPromise(
    Effect.gen(function* () { return yield* RelayRepository; }).pipe(
      Effect.provide(RelayRepositoryLive),
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
      iroh_relay_preferences,
      iroh_relay_catalog_state,
      account_deletion_tombstones
    restart identity cascade
  `;
});

afterAll(async () => {
  await closeCloudDbForTests();
  await sql?.end();
});

describe("Iroh trust broker database behavior", () => {
  dbTest("validates the expanded relay issuance status constraint", async () => {
    const [constraint] = await requiredSql()<Array<{ validated: boolean }>>`
      select convalidated as validated
      from pg_constraint
      where conname = 'iroh_relay_token_issuances_status_check'
        and conrelid = 'iroh_relay_token_issuances'::regclass
    `;

    expect(constraint).toEqual({ validated: true });
  });

  dbTest("serializes and rejects unsafe managed relay catalog activation", async () => {
    const current: RelayCatalog = {
      version: 1,
      sequence: 20,
      relays: [{
        id: "relay-a",
        provider: "cmux",
        region: "A",
        url: "https://relay-a.cmux.dev/",
      }],
    };
    const added: RelayCatalog = {
      ...current,
      sequence: 21,
      relays: [
        ...current.relays,
        {
          id: "relay-b",
          provider: "cmux",
          region: "B",
          url: "https://relay-b.cmux.dev/",
        },
      ],
    };
    const removed: RelayCatalog = {
      ...added,
      sequence: 22,
      relays: [added.relays[1]!],
    };
    const acceptCatalog = requiredRelayRepository().acceptCatalog as unknown as (
      input: { readonly catalog: RelayCatalog; readonly nowSeconds: number },
    ) => Effect.Effect<void, unknown>;

    await Effect.runPromise(acceptCatalog({ catalog: current, nowSeconds: 1_000 }));
    await Effect.runPromise(acceptCatalog({ catalog: added, nowSeconds: 1_001 }));

    const earlyRemoval = await Effect.runPromiseExit(
      acceptCatalog({ catalog: removed, nowSeconds: 1_300 }),
    );
    expect(earlyRemoval._tag).toBe("Failure");
    expect(String(earlyRemoval)).toContain("unsafe_transition");

    await Effect.runPromise(acceptCatalog({ catalog: removed, nowSeconds: 1_301 }));
    const [state] = await requiredSql()<Array<{
      sequence: string;
      catalog: RelayCatalog;
    }>>`
      select catalog_sequence::text as sequence, catalog
      from iroh_relay_catalog_state
      where id = 'managed'
    `;
    expect(state).toEqual({ sequence: "22", catalog: removed });
  });

  dbTest("fails closed when the persisted relay catalog digest is corrupt", async () => {
    const current: RelayCatalog = {
      version: 1,
      sequence: 30,
      relays: [{
        id: "relay-a",
        provider: "cmux",
        region: "A",
        url: "https://relay-a.cmux.dev/",
      }],
    };
    const next: RelayCatalog = {
      ...current,
      sequence: 31,
      relays: [
        ...current.relays,
        {
          id: "relay-b",
          provider: "cmux",
          region: "B",
          url: "https://relay-b.cmux.dev/",
        },
      ],
    };
    await requiredSql()`
      insert into iroh_relay_catalog_state (
        id, catalog_sequence, catalog_digest, catalog, updated_at
      ) values (
        'managed', ${current.sequence}, ${"0".repeat(64)}, ${requiredSql().json(current)},
        to_timestamp(1_000)
      )
    `;

    const exit = await Effect.runPromiseExit(
      requiredRelayRepository().acceptCatalog({ catalog: next, nowSeconds: 1_001 }),
    );

    expect(exit._tag).toBe("Failure");
    expect(String(exit)).toContain("RelayCatalogIntegrityError");
    expect(String(exit)).toContain("persisted_catalog_digest_mismatch");
    const [state] = await requiredSql()<Array<{ sequence: string }>>`
      select catalog_sequence::text as sequence
      from iroh_relay_catalog_state
      where id = 'managed'
    `;
    expect(state).toEqual({ sequence: "30" });
  });

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
      repository.discoverySnapshot({ userId, now: NOW }),
      repository.pruneExpiredState({ userId, now: NOW }),
      repository.finalizeEndpointAttestation({
        userId,
        bindingId: ios.bindingId,
        deviceId: ios.deviceId,
        endpointId: ios.endpointId,
        identityGeneration: ios.identityGeneration,
        platform: ios.platform,
      }),
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
        pathHints: [],
      },
      now: NOW,
      bindingQuota: { account: 32, device: 8, baselineDevice: 8, staleAfterMs: null },
    }));
    const results = await Promise.allSettled([register(), register()]);
    expect(results.filter((result) => result.status === "fulfilled")).toHaveLength(1);
    expect(results.filter((result) => result.status === "rejected")).toHaveLength(1);
    const [{ bindings, consumed, nextExpiry, pathHints }] = await requiredSql()<Array<{
      bindings: string;
      consumed: string;
      nextExpiry: Date | null;
      pathHints: unknown[];
    }>>`
      select
        (select count(*)::text from iroh_endpoint_bindings) as bindings,
        (select count(*)::text from iroh_registration_challenges where consumed_at is not null) as consumed,
        (select path_hints_next_expiry from iroh_endpoint_bindings limit 1) as "nextExpiry",
        (select path_hints from iroh_endpoint_bindings limit 1) as "pathHints"
    `;
    expect({ bindings, consumed }).toEqual({ bindings: "1", consumed: "1" });
    expect(nextExpiry).toBeNull();
    expect(pathHints).toEqual([]);
  });

  dbTest("recycles the least-recently-seen stale development binding under pressure", async () => {
    const repo = requiredRepository();
    const userId = "user-development-recycling";
    const deviceId = randomUUID();
    const oldestId = await insertBinding({
      userId,
      deviceUuid: deviceId,
      endpointId: "21".repeat(32),
    });
    const newerInactiveId = await insertBinding({
      userId,
      deviceUuid: deviceId,
      endpointId: "22".repeat(32),
    });
    await insertBinding({ userId, deviceUuid: deviceId, endpointId: "23".repeat(32) });
    await insertBinding({ userId, deviceUuid: deviceId, endpointId: "24".repeat(32) });
    await requiredSql()`
      update iroh_endpoint_bindings
      set last_seen_at = case id
        when ${oldestId} then ${new Date(NOW.getTime() - 72 * 60 * 60 * 1_000)}
        when ${newerInactiveId} then ${new Date(NOW.getTime() - 48 * 60 * 60 * 1_000)}
        else ${NOW}
      end
      where user_id = ${userId}
    `;

    const appInstanceId = randomUUID();
    const endpointId = "25".repeat(32);
    const nonceHash = "26".repeat(32);
    const challenge = await Effect.runPromise(repo.issueChallenge({
      userId,
      deviceUuid: deviceId,
      appInstanceId,
      tag: "newest",
      endpointId,
      identityGeneration: 1,
      payloadSha256: "27".repeat(32),
      nonceHash,
      now: NOW,
      expiresAt: new Date(NOW.getTime() + 5 * 60 * 1_000),
    }));
    await Effect.runPromise(repo.consumeChallengeAndRegister({
      userId,
      challengeId: challenge.id,
      nonceHash,
      payload: {
        route_contract_version: 1,
        deviceId,
        appInstanceId,
        tag: "newest",
        platform: "mac",
        endpointId,
        identityGeneration: 1,
        pairingEnabled: true,
        capabilities: [],
        pathHints: [],
      },
      now: NOW,
      bindingQuota: {
        account: 8,
        device: 4,
        baselineDevice: 8,
        staleAfterMs: 24 * 60 * 60 * 1_000,
      },
    }));

    const [state] = await requiredSql()<Array<{
      active: string;
      oldestReason: string | null;
      newerInactive: boolean;
      generation: number;
    }>>`
      select
        (select count(*)::text from iroh_endpoint_bindings
          where user_id = ${userId} and revoked_at is null) as active,
        (select revoked_reason from iroh_endpoint_bindings
          where id = ${oldestId}) as "oldestReason",
        exists(select 1 from iroh_endpoint_bindings
          where id = ${newerInactiveId} and revoked_at is null) as "newerInactive",
        (select lan_discovery_generation from iroh_account_security_states
          where user_id = ${userId}) as generation
    `;
    expect(state).toEqual({
      active: "4",
      oldestReason: "stale_development_binding",
      newerInactive: true,
      generation: 2,
    });
  });

  dbTest("persists account-private path hints already filtered by the trust broker", async () => {
    const repo = requiredRepository();
    const userId = "user-private-registration-hints";
    const deviceId = randomUUID();
    const appInstanceId = randomUUID();
    const endpointId = "40".repeat(32);
    const nonceHash = "41".repeat(32);
    const directExpiry = new Date(NOW.getTime() + 20 * 60 * 1_000);
    const relayExpiry = new Date(NOW.getTime() + 30 * 60 * 1_000);
    const pathHints: Parameters<
      IrohRepositoryShape["consumeChallengeAndRegister"]
    >[0]["payload"]["pathHints"] = [
      {
        kind: "direct_address",
        value: "8.8.4.4:4433",
        source: "native",
        privacy_scope: "public_internet",
        observed_at: new Date(NOW.getTime() - 5 * 60 * 1_000).toISOString(),
        expires_at: directExpiry.toISOString(),
      },
      {
        kind: "relay_url",
        value: "https://relay.example.net/",
        source: "native",
        privacy_scope: "public_internet",
        observed_at: new Date(NOW.getTime() - 5 * 60 * 1_000).toISOString(),
        expires_at: relayExpiry.toISOString(),
      },
    ];
    const challenge = await Effect.runPromise(repo.issueChallenge({
      userId,
      deviceUuid: deviceId,
      appInstanceId,
      tag: "stable",
      endpointId,
      identityGeneration: 1,
      payloadSha256: "42".repeat(32),
      nonceHash,
      now: NOW,
      expiresAt: new Date(NOW.getTime() + 5 * 60 * 1_000),
    }));

    await Effect.runPromise(repo.consumeChallengeAndRegister({
      userId,
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
        pathHints,
      },
      now: NOW,
      bindingQuota: { account: 32, device: 8, baselineDevice: 8, staleAfterMs: null },
    }));

    const [stored] = await requiredSql()<Array<{
      pathHints: unknown[];
      nextExpiry: Date | null;
    }>>`
      select
        path_hints as "pathHints",
        path_hints_next_expiry as "nextExpiry"
      from iroh_endpoint_bindings
      where app_instance_id = ${appInstanceId}
    `;
    expect(stored?.pathHints).toEqual(pathHints);
    expect(stored?.nextExpiry).toEqual(directExpiry);
  });

  dbTest("persists, updates, and clears family-specific direct ports", async () => {
    const repo = requiredRepository();
    const userId = "user-direct-ports";
    const deviceId = randomUUID();
    const appInstanceId = randomUUID();
    const endpointId = "4f".repeat(32);
    type DirectPorts = { readonly ipv4?: number; readonly ipv6?: number };

    const register = async (
      directPorts: DirectPorts | undefined,
      sequence: number,
    ): Promise<void> => {
      const now = new Date(NOW.getTime() + sequence * 1_000);
      const nonceHash = sequence.toString(16).padStart(64, "0");
      const challenge = await Effect.runPromise(repo.issueChallenge({
        userId,
        deviceUuid: deviceId,
        appInstanceId,
        tag: "stable",
        endpointId,
        identityGeneration: 1,
        payloadSha256: (sequence + 10).toString(16).padStart(64, "0"),
        nonceHash,
        now,
        expiresAt: new Date(now.getTime() + 5 * 60 * 1_000),
      }));
      const payload: Parameters<
        IrohRepositoryShape["consumeChallengeAndRegister"]
      >[0]["payload"] & { readonly directPorts?: DirectPorts } = {
        route_contract_version: 1,
        deviceId,
        appInstanceId,
        tag: "stable",
        platform: "mac",
        endpointId,
        identityGeneration: 1,
        pairingEnabled: true,
        capabilities: [],
        ...(directPorts ? { directPorts } : {}),
        pathHints: [],
      };
      await Effect.runPromise(repo.consumeChallengeAndRegister({
        userId,
        challengeId: challenge.id,
        nonceHash,
        payload,
        now,
        bindingQuota: { account: 32, device: 8, baselineDevice: 8, staleAfterMs: null },
      }));
    };

    await register({ ipv4: 49_152, ipv6: 49_153 }, 1);
    let [stored] = await requiredSql()<Array<{
      directPortV4: number | null;
      directPortV6: number | null;
    }>>`
      select
        direct_port_v4 as "directPortV4",
        direct_port_v6 as "directPortV6"
      from iroh_endpoint_bindings
      where app_instance_id = ${appInstanceId}
    `;
    expect(stored).toEqual({ directPortV4: 49_152, directPortV6: 49_153 });

    await register({ ipv6: 50_000 }, 2);
    [stored] = await requiredSql()<Array<{
      directPortV4: number | null;
      directPortV6: number | null;
    }>>`
      select
        direct_port_v4 as "directPortV4",
        direct_port_v6 as "directPortV6"
      from iroh_endpoint_bindings
      where app_instance_id = ${appInstanceId}
    `;
    expect(stored).toEqual({ directPortV4: null, directPortV6: 50_000 });

    await register(undefined, 3);
    [stored] = await requiredSql()<Array<{
      directPortV4: number | null;
      directPortV6: number | null;
    }>>`
      select
        direct_port_v4 as "directPortV4",
        direct_port_v6 as "directPortV6"
      from iroh_endpoint_bindings
      where app_instance_id = ${appInstanceId}
    `;
    expect(stored).toEqual({ directPortV4: null, directPortV6: null });
  });

  dbTest("requires revocation before changing an active binding platform", async () => {
    const repo = requiredRepository();
    const userId = "user-platform-change";
    const deviceId = randomUUID();
    const appInstanceId = randomUUID();
    const endpointId = "31".repeat(32);

    const register = async (platform: "mac" | "ios", suffix: string, now: Date) => {
      const nonceHash = suffix.repeat(64);
      const challenge = await Effect.runPromise(repo.issueChallenge({
        userId,
        deviceUuid: deviceId,
        appInstanceId,
        tag: "stable",
        endpointId,
        identityGeneration: 1,
        payloadSha256: `${suffix}${"0".repeat(63)}`,
        nonceHash,
        now,
        expiresAt: new Date(now.getTime() + 5 * 60 * 1_000),
      }));
      return repo.consumeChallengeAndRegister({
        userId,
        challengeId: challenge.id,
        nonceHash,
        payload: {
          route_contract_version: 1,
          deviceId,
          appInstanceId,
          tag: "stable",
          platform,
          endpointId,
          identityGeneration: 1,
          pairingEnabled: platform === "mac",
          capabilities: [],
          pathHints: [],
        },
        now,
        bindingQuota: { account: 32, device: 8, baselineDevice: 8, staleAfterMs: null },
      });
    };

    await Effect.runPromise(await register("mac", "5", NOW));
    const changed = await Effect.runPromiseExit(await register(
      "ios",
      "6",
      new Date(NOW.getTime() + 1_000),
    ));
    expect(changed._tag).toBe("Failure");
    const causeError = changed._tag === "Failure"
      ? (changed.cause as unknown as { error?: unknown }).error
      : undefined;
    expect(causeError).toMatchObject({
      _tag: "IrohConflictError",
      code: "binding_replacement_requires_revocation",
    });
    const [{ platform }] = await requiredSql()<Array<{ platform: string }>>`
      select platform from iroh_endpoint_bindings where app_instance_id = ${appInstanceId}
    `;
    expect(platform).toBe("mac");
  });

  dbTest("serializes an account-wide registration challenge rate cap", async () => {
    const userId = "user-challenge-flood";
    await requiredSql()`
      insert into iroh_registration_challenges (
        user_id, device_uuid, app_instance_id, tag, endpoint_id,
        identity_generation, payload_sha256, nonce_hash, created_at, expires_at, consumed_at
      )
      select
        ${userId}, gen_random_uuid(), gen_random_uuid(), 'stable', repeat('3a', 32),
        1,
        md5('account-payload-a-' || value::text) || md5('account-payload-b-' || value::text),
        md5('account-nonce-a-' || value::text) || md5('account-nonce-b-' || value::text),
        ${new Date(NOW.getTime() - 60_000)}, ${new Date(NOW.getTime() + 60_000)}, ${NOW}
      from generate_series(1, 119) as values(value)
    `;
    const issue = (suffix: string) => Effect.runPromiseExit(requiredRepository().issueChallenge({
      userId,
      deviceUuid: randomUUID(),
      appInstanceId: randomUUID(),
      tag: "stable",
      endpointId: suffix.repeat(64),
      identityGeneration: 1,
      payloadSha256: suffix.repeat(64),
      nonceHash: `${suffix}${"0".repeat(63)}`,
      now: NOW,
      expiresAt: new Date(NOW.getTime() + 5 * 60 * 1_000),
    }));

    const results = await Promise.all([issue("4"), issue("5")]);
    expect(results.filter((result) => result._tag === "Success")).toHaveLength(1);
    expect(results.filter((result) => result._tag === "Failure")).toHaveLength(1);
    const failure = results.find((result) => result._tag === "Failure");
    const causeError = failure?._tag === "Failure"
      ? (failure.cause as unknown as { error?: unknown }).error
      : undefined;
    expect(causeError).toMatchObject({
      _tag: "IrohQuotaExceededError",
      code: "challenge_account_rate_limited",
    });
    const [{ total }] = await requiredSql()<Array<{ total: string }>>`
      select count(*)::text as total
      from iroh_registration_challenges
      where user_id = ${userId}
    `;
    expect(total).toBe("120");
  });

  dbTest("allows forty same-device challenges under an explicit development quota", async () => {
    const userId = "user-development-challenges";
    const deviceUuid = randomUUID();
    const results = await Promise.all(Array.from({ length: 40 }, (_, index) => {
      const suffix = (index + 1).toString(16).padStart(64, "0");
      const input = {
        userId,
        deviceUuid,
        appInstanceId: randomUUID(),
        tag: `dev-${index + 1}`,
        endpointId: suffix,
        identityGeneration: 1,
        payloadSha256: suffix,
        nonceHash: (index + 101).toString(16).padStart(64, "0"),
        now: NOW,
        expiresAt: new Date(NOW.getTime() + 5 * 60 * 1_000),
        challengeQuota: { account: 2_048, deviceInstance: 128, outstanding: 256 },
      } as Parameters<IrohRepositoryShape["issueChallenge"]>[0];
      return Effect.runPromiseExit(requiredRepository().issueChallenge(input));
    }));

    expect(results.filter((result) => result._tag === "Success")).toHaveLength(40);
    const [{ total }] = await requiredSql()<Array<{ total: string }>>`
      select count(*)::text as total
      from iroh_registration_challenges
      where user_id = ${userId}
    `;
    expect(total).toBe("40");
  });

  dbTest("scopes challenge burst quota to an exact device app instance", async () => {
    const userId = "user-instance-scoped-challenges";
    const deviceUuid = randomUUID();
    const firstAppInstanceId = randomUUID();
    const secondAppInstanceId = randomUUID();
    const issue = (appInstanceId: string, index: number) => {
      const suffix = index.toString(16).padStart(64, "0");
      return Effect.runPromiseExit(requiredRepository().issueChallenge({
        userId,
        deviceUuid,
        appInstanceId,
        tag: appInstanceId === firstAppInstanceId ? "dev-first" : "dev-second",
        endpointId: suffix,
        identityGeneration: 1,
        payloadSha256: suffix,
        nonceHash: (index + 100).toString(16).padStart(64, "0"),
        now: NOW,
        expiresAt: new Date(NOW.getTime() + 5 * 60 * 1_000),
        challengeQuota: { account: 10, deviceInstance: 2, outstanding: 10 },
      }));
    };

    expect((await issue(firstAppInstanceId, 1))._tag).toBe("Success");
    expect((await issue(firstAppInstanceId, 2))._tag).toBe("Success");

    const firstInstanceOverflow = await issue(firstAppInstanceId, 3);
    expect(firstInstanceOverflow._tag).toBe("Failure");
    const causeError = firstInstanceOverflow._tag === "Failure"
      ? (firstInstanceOverflow.cause as unknown as { error?: unknown }).error
      : undefined;
    expect(causeError).toMatchObject({
      _tag: "IrohQuotaExceededError",
      code: "challenge_rate_limited",
    });

    expect((await issue(secondAppInstanceId, 4))._tag).toBe("Success");
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

  dbTest("enforces the UDP port range for each direct-address family", async () => {
    const bindingId = await insertBinding({
      userId: "user-direct-port-checks",
      endpointId: "4e".repeat(32),
    });
    await expectPostgresError(requiredSql()`
      update iroh_endpoint_bindings set direct_port_v4 = 0 where id = ${bindingId}
    `, "23514");
    await expectPostgresError(requiredSql()`
      update iroh_endpoint_bindings set direct_port_v4 = 65536 where id = ${bindingId}
    `, "23514");
    await expectPostgresError(requiredSql()`
      update iroh_endpoint_bindings set direct_port_v6 = 0 where id = ${bindingId}
    `, "23514");
    await expectPostgresError(requiredSql()`
      update iroh_endpoint_bindings set direct_port_v6 = 65536 where id = ${bindingId}
    `, "23514");

    await requiredSql()`
      update iroh_endpoint_bindings
      set direct_port_v4 = 1, direct_port_v6 = 65535
      where id = ${bindingId}
    `;
    const [stored] = await requiredSql()<Array<{
      directPortV4: number | null;
      directPortV6: number | null;
    }>>`
      select
        direct_port_v4 as "directPortV4",
        direct_port_v6 as "directPortV6"
      from iroh_endpoint_bindings
      where id = ${bindingId}
    `;
    expect(stored).toEqual({ directPortV4: 1, directPortV6: 65_535 });
  });

  dbTest("scrubs direct ports when a binding is revoked", async () => {
    const repo = requiredRepository();
    const bindingId = await insertBinding({
      userId: "user-revoked-direct-ports",
      endpointId: "4d".repeat(32),
    });
    await requiredSql()`
      update iroh_endpoint_bindings
      set direct_port_v4 = 49_152, direct_port_v6 = 49_153
      where id = ${bindingId}
    `;

    expect(await Effect.runPromise(repo.revokeBinding({
      userId: "user-revoked-direct-ports",
      bindingId,
      now: NOW,
    }))).toBe(true);

    const [stored] = await requiredSql()<Array<{
      directPortV4: number | null;
      directPortV6: number | null;
    }>>`
      select
        direct_port_v4 as "directPortV4",
        direct_port_v6 as "directPortV6"
      from iroh_endpoint_bindings
      where id = ${bindingId}
    `;
    expect(stored).toEqual({ directPortV4: null, directPortV6: null });
  });

  dbTest("keeps LAN discovery account-scoped and coherent across binding revocation", async () => {
    const repo = requiredRepository();
    const userId = "user-lan-revoke";
    const firstBindingId = await insertBinding({
      userId,
      endpointId: "44".repeat(32),
    });
    const secondBindingId = await insertBinding({
      userId,
      endpointId: "45".repeat(32),
    });
    const otherBindingId = await insertBinding({
      userId: "user-lan-other",
      endpointId: "46".repeat(32),
    });

    const initial = await Effect.runPromise(repo.discoverySnapshot({ userId, now: NOW }));
    const otherInitial = await Effect.runPromise(repo.discoverySnapshot({
      userId: "user-lan-other",
      now: NOW,
    }));
    expect(initial.lanDiscoveryGeneration).toBe(1);
    expect(initial.bindings.map((binding) => binding.id).sort()).toEqual([
      firstBindingId,
      secondBindingId,
    ].sort());
    expect(otherInitial).toMatchObject({
      lanDiscoveryGeneration: 1,
      bindings: [{ id: otherBindingId }],
    });

    expect(await Effect.runPromise(repo.revokeBinding({
      userId,
      bindingId: firstBindingId,
      now: NOW,
    }))).toBe(true);
    const afterFirstRevoke = await Effect.runPromise(repo.discoverySnapshot({ userId, now: NOW }));
    expect(afterFirstRevoke.lanDiscoveryGeneration).toBe(2);
    expect(afterFirstRevoke.bindings.map((binding) => binding.id)).toEqual([secondBindingId]);
    expect(await Effect.runPromise(repo.revokeBinding({
      userId,
      bindingId: firstBindingId,
      now: new Date(NOW.getTime() + 60_000),
    }))).toBe(true);
    const [retriedBinding] = await requiredSql()<Array<{ revokedAt: Date }>>`
      select revoked_at as "revokedAt"
      from iroh_endpoint_bindings
      where id = ${firstBindingId}
    `;
    expect(retriedBinding?.revokedAt).toEqual(NOW);
    expect((await Effect.runPromise(repo.discoverySnapshot({ userId, now: NOW }))).lanDiscoveryGeneration).toBe(2);
    expect(await Effect.runPromise(repo.revokeBinding({
      userId: "user-lan-other",
      bindingId: firstBindingId,
      now: NOW,
    }))).toBe(false);
    expect(await Effect.runPromise(repo.revokeBinding({
      userId,
      bindingId: randomUUID(),
      now: NOW,
    }))).toBe(false);

    let concurrentDiscovery: ReturnType<typeof Effect.runPromise> | undefined;
    await requiredSql().begin(async (revocationSql) => {
      await revocationSql`
        select pg_advisory_xact_lock(hashtextextended(${`iroh:binding:${userId}`}, 0))
      `;
      await revocationSql`
        update iroh_endpoint_bindings
        set revoked_at = ${NOW}, revoked_reason = 'user_requested',
            path_hints = '[]'::jsonb, path_hints_next_expiry = null, updated_at = ${NOW}
        where id = ${secondBindingId} and user_id = ${userId} and revoked_at is null
      `;
      await revocationSql`
        update iroh_account_security_states
        set lan_discovery_generation = lan_discovery_generation + 1, updated_at = ${NOW}
        where user_id = ${userId}
      `;
      concurrentDiscovery = Effect.runPromise(repo.discoverySnapshot({ userId, now: NOW }));
      await waitForAdvisoryLockWaiter();
    });
    if (!concurrentDiscovery) throw new Error("concurrent discovery was not started");
    const afterConcurrentRevoke = await concurrentDiscovery;
    expect(afterConcurrentRevoke).toMatchObject({
      lanDiscoveryGeneration: 3,
      bindings: [],
    });
    const otherAfter = await Effect.runPromise(repo.discoverySnapshot({
      userId: "user-lan-other",
      now: NOW,
    }));
    expect(otherAfter).toMatchObject({
      lanDiscoveryGeneration: 1,
      bindings: [{ id: otherBindingId }],
    });
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

  dbTest("rejects pair-grant peers that resolve to one physical device", async () => {
    const userId = "user-pair-same-device";
    const deviceUuid = randomUUID();
    const initiatorId = await insertBinding({
      userId,
      deviceUuid,
      platform: "ios",
      endpointId: "54".repeat(32),
    });
    const acceptorId = await insertBinding({
      userId,
      deviceUuid,
      platform: "mac",
      endpointId: "55".repeat(32),
    });
    const exit = await Effect.runPromiseExit(requiredRepository().recordPairGrant({
      userId,
      jti: randomUUID(),
      initiator: await pairPeer(initiatorId),
      acceptor: await pairPeer(acceptorId),
      signingKeyId: "current",
      alpn: "cmux/mobile/1",
      scope: "cmux.mobile.attach",
      issuedAt: NOW,
      notBefore: NOW,
      expiresAt: new Date(NOW.getTime() + 7 * 24 * 60 * 60 * 1_000),
    }));

    expect(exit._tag).toBe("Failure");
    expect(String(exit)).toContain("pair_grant_same_device");
  });

  dbTest("fails attestation finalization when revocation commits during signing", async () => {
    const userId = "user-attestation-race";
    const bindingId = await insertBinding({
      userId,
      platform: "ios",
      endpointId: "56".repeat(32),
    });
    const peer = await pairPeer(bindingId);
    let finalization: ReturnType<typeof Effect.runPromiseExit> | undefined;
    await requiredSql().begin(async (revocationSql) => {
      await revocationSql`
        select pg_advisory_xact_lock(hashtextextended(${`iroh:binding:${userId}`}, 0))
      `;
      finalization = Effect.runPromiseExit(requiredRepository().finalizeEndpointAttestation({
        userId,
        bindingId,
        deviceId: peer.deviceId,
        endpointId: peer.endpointId,
        identityGeneration: peer.identityGeneration,
        platform: peer.platform,
      }));
      await waitForAdvisoryLockWaiter();
      await revocationSql`
        update iroh_endpoint_bindings
        set revoked_at = ${NOW}, revoked_reason = 'user_requested'
        where id = ${bindingId}
      `;
    });

    if (!finalization) throw new Error("attestation finalization was not started");
    const exit = await finalization;
    expect(exit._tag).toBe("Failure");
    expect(String(exit)).toContain("IrohNotFoundError");
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

  dbTest("expires abandoned relay reservations before enforcing endpoint and account quotas", async () => {
    const repo = requiredRepository();
    const endpointUserId = "user-relay-abandoned-endpoint";
    const endpointBindingId = await insertBinding({
      userId: endpointUserId,
      endpointId: "63".repeat(32),
    });
    for (let index = 0; index < 3; index += 1) {
      await requiredSql()`
        insert into iroh_relay_token_issuances (
          user_id, binding_id, endpoint_id_hash, status, requested_at
        ) values (
          ${endpointUserId}, ${endpointBindingId}, ${"64".repeat(32)}, 'pending',
          ${new Date(NOW.getTime() - 5 * 60 * 1_000 - index * 1_000)}
        )
      `;
    }

    await Effect.runPromise(repo.reserveRelayIssuance({
      userId: endpointUserId,
      bindingId: endpointBindingId,
      now: NOW,
    }));
    const endpointStatuses = await requiredSql()<Array<{ status: string; total: string }>>`
      select status, count(*)::text as total
      from iroh_relay_token_issuances
      where user_id = ${endpointUserId}
      group by status
      order by status
    `;
    expect(endpointStatuses).toEqual([
      { status: "expired", total: "3" },
      { status: "pending", total: "1" },
    ]);

    const accountUserId = "user-relay-abandoned-account";
    const accountBindingIds: string[] = [];
    for (let index = 0; index < 10; index += 1) {
      const bindingId = await insertBinding({
        userId: accountUserId,
        endpointId: (0xa0 + index).toString(16).repeat(32),
      });
      accountBindingIds.push(bindingId);
      await requiredSql()`
        insert into iroh_relay_token_issuances (
          user_id, binding_id, endpoint_id_hash, status, requested_at
        )
        select
          ${accountUserId}, ${bindingId}, ${"65".repeat(32)}, 'pending',
          ${new Date(NOW.getTime() - 15 * 60 * 1_000)} - make_interval(secs => value)
        from generate_series(1, 10) as values(value)
      `;
    }

    await Effect.runPromise(repo.reserveRelayIssuance({
      userId: accountUserId,
      bindingId: accountBindingIds[0]!,
      now: NOW,
    }));
    const accountStatuses = await requiredSql()<Array<{ status: string; total: string }>>`
      select status, count(*)::text as total
      from iroh_relay_token_issuances
      where user_id = ${accountUserId}
      group by status
      order by status
    `;
    expect(accountStatuses).toEqual([
      { status: "expired", total: "100" },
      { status: "pending", total: "1" },
    ]);
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
    const legacyRevokedId = await insertBinding({
      userId: "user-retention",
      endpointId: "84".repeat(32),
    });
    await requiredSql()`
      update iroh_endpoint_bindings
      set revoked_at = ${new Date(NOW.getTime() - 31 * 24 * 60 * 60 * 1_000)}
      where id = ${oldRevokedId}
    `;
    await requiredSql()`
      update iroh_endpoint_bindings
      set
        revoked_at = ${NOW},
        direct_port_v4 = 49_152,
        direct_port_v6 = 49_153
      where id = ${legacyRevokedId}
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
    const [legacyRevoked] = await requiredSql()<Array<{
      directPortV4: number | null;
      directPortV6: number | null;
    }>>`
      select
        direct_port_v4 as "directPortV4",
        direct_port_v6 as "directPortV6"
      from iroh_endpoint_bindings
      where id = ${legacyRevokedId}
    `;
    expect(legacyRevoked).toEqual({ directPortV4: null, directPortV6: null });
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

  dbTest("retention skips locked hint rows and drains multiple indexed batches", async () => {
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
      from generate_series(1, ${IROH_RETENTION_BATCH_SIZE * 2 + 1}) as values(value)
    `;
    await Effect.runPromise(requiredRepository().pruneExpiredStateGlobally({ now: NOW }));
    const [{ remaining }] = await requiredSql()<Array<{ remaining: string }>>`
      select count(*)::text as remaining
      from iroh_registration_challenges
      where user_id = 'user-retention-batch'
    `;
    expect(remaining).toBe("0");

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

  dbTest("global retention reports backlog when its row budget is exhausted", async () => {
    await requiredSql()`
      insert into iroh_registration_challenges (
        user_id, device_uuid, app_instance_id, tag, endpoint_id,
        identity_generation, payload_sha256, nonce_hash, created_at, expires_at
      )
      select
        'user-retention-budget', gen_random_uuid(), gen_random_uuid(), 'stable',
        repeat('88', 32), 1,
        md5('budget-payload-a-' || value::text) || md5('budget-payload-b-' || value::text),
        md5('budget-nonce-a-' || value::text) || md5('budget-nonce-b-' || value::text),
        ${new Date(NOW.getTime() - 3 * 24 * 60 * 60 * 1_000)},
        ${new Date(NOW.getTime() - 2 * 24 * 60 * 60 * 1_000)}
      from generate_series(1, ${IROH_RETENTION_BATCH_SIZE + 1}) as values(value)
    `;
    const cleanupInput = {
      now: NOW,
      maxRows: IROH_RETENTION_BATCH_SIZE,
      maxDurationMs: 30_000,
    };
    const result = await Effect.runPromise(
      requiredRepository().pruneExpiredStateGlobally(cleanupInput),
    ) as unknown as {
      rowsProcessed: number;
      backlog: boolean;
      budgetExhausted: "rows" | "time" | null;
      byCategory: { expiredChallenges: number };
    };

    expect(result).toMatchObject({
      rowsProcessed: IROH_RETENTION_BATCH_SIZE,
      backlog: true,
      budgetExhausted: "rows",
      byCategory: { expiredChallenges: IROH_RETENTION_BATCH_SIZE },
    });
    const [{ remaining }] = await requiredSql()<Array<{ remaining: string }>>`
      select count(*)::text as remaining
      from iroh_registration_challenges
      where user_id = 'user-retention-budget'
    `;
    expect(remaining).toBe("1");
  });

  dbTest("retention and cascade lookups use their dedicated indexes", async () => {
    const userId = "user-retention-index-plan";
    const initiatorId = await insertBinding({
      userId,
      platform: "ios",
      endpointId: "89".repeat(32),
    });
    const acceptorId = await insertBinding({
      userId,
      platform: "mac",
      endpointId: "8a".repeat(32),
    });
    await requiredSql()`
      insert into iroh_pair_grant_issuances (
        user_id, jti, initiator_binding_id, acceptor_binding_id, signing_key_id,
        alpn, scope, issued_at, not_before, expires_at
      ) values (
        ${userId}, ${randomUUID()}, ${initiatorId}, ${acceptorId}, 'current',
        'cmux/mobile/1', 'cmux.mobile.attach', ${NOW}, ${NOW}, ${new Date(NOW.getTime() + 1_000)}
      )
    `;
    await requiredSql()`
      update iroh_endpoint_bindings
      set revoked_at = ${new Date(NOW.getTime() - 31 * 24 * 60 * 60 * 1_000)}
      where id = ${initiatorId}
    `;

    await requiredSql().begin(async (planSql) => {
      await planSql`set local enable_seqscan = off`;
      const initiatorPlan = await planSql`
        explain (format json)
        select id
        from iroh_pair_grant_issuances
        where initiator_binding_id = ${initiatorId}
      `;
      const fullUserPlan = await planSql`
        explain (format json)
        select id
        from iroh_endpoint_bindings
        where user_id = ${userId}
      `;
      const revokedCleanupPlan = await planSql`
        explain (format json)
        select id
        from iroh_endpoint_bindings
        where user_id = ${userId}
          and revoked_at < ${NOW}
        order by revoked_at, id
      `;

      expect(JSON.stringify(initiatorPlan)).toContain("iroh_pair_grant_issuances_initiator_idx");
      expect(JSON.stringify(fullUserPlan)).toContain("iroh_endpoint_bindings_user_idx");
      expect(JSON.stringify(revokedCleanupPlan)).toContain("iroh_endpoint_bindings_user_revoked_idx");
    });
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
  readonly deviceUuid?: string;
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
      ${input.userId}, ${input.deviceUuid ?? randomUUID()}, ${input.appInstanceId ?? randomUUID()}, 'stable',
      ${input.platform ?? "mac"}, ${input.endpointId}, 1, true, '[]'::jsonb,
      ${requiredSql().json((input.pathHints ?? []) as never)},
      ${earliestStoredHintExpiry(input.pathHints ?? [])}
    ) returning id::text
  `;
  if (!row) throw new Error("binding insert returned no row");
  return row.id;
}

function requiredRelayRepository(): RelayRepositoryShape {
  if (!relayRepository) throw new Error("relay repository not initialized");
  return relayRepository;
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
