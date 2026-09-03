import { afterAll, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { randomUUID } from "node:crypto";
import * as Cause from "effect/Cause";
import * as Effect from "effect/Effect";
import * as Option from "effect/Option";
import postgres, { type Sql } from "postgres";
import { closeCloudDbForTests } from "../db/client";
import {
  accountDeletionAdvisoryLockKey,
  accountDeletionUserHash,
} from "../services/account/deletionLock";
import type { PairGrantPeer } from "../services/iroh/crypto";
import { RELAY_ROTATION_MIN_OVERLAP_SECONDS } from "../services/relay/catalog";
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
      acceptCatalog({
        catalog: removed,
        nowSeconds: 1_001 + RELAY_ROTATION_MIN_OVERLAP_SECONDS - 1,
      }),
    );
    expect(earlyRemoval._tag).toBe("Failure");
    expect(String(earlyRemoval)).toContain("unsafe_transition");

    await Effect.runPromise(acceptCatalog({
      catalog: removed,
      nowSeconds: 1_001 + RELAY_ROTATION_MIN_OVERLAP_SECONDS,
    }));
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
      repository.discoveryPage({ userId, now: NOW, pageSize: 256 }),
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
        clientNamespace: "legacy",
        tag: "stable",
        platform: "mac",
        endpointId,
        identityGeneration: 1,
        pairingEnabled: true,
        capabilities: [],
        pathHints: [],
      },
      now: NOW,
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

  dbTest("adopts legacy and tag-only Mac bindings into the bundle namespace", async () => {
    const repo = requiredRepository();
    const userId = "user-legacy-namespace-adoption";
    const deviceId = randomUUID();
    const endpointId = "35".repeat(32);

    const register = async (
      appInstanceId: string,
      clientNamespace: string,
      nonceHash: string,
    ) => {
      const challenge = await Effect.runPromise(repo.issueChallenge({
        userId,
        deviceUuid: deviceId,
        appInstanceId,
        clientNamespace,
        tag: "stable",
        endpointId,
        identityGeneration: 1,
        payloadSha256: "36".repeat(32),
        nonceHash,
        now: NOW,
        expiresAt: new Date(NOW.getTime() + 5 * 60 * 1_000),
      }));
      return await Effect.runPromise(repo.consumeChallengeAndRegister({
        userId,
        challengeId: challenge.id,
        nonceHash,
        payload: {
          route_contract_version: 1,
          deviceId,
          appInstanceId,
          clientNamespace,
          tag: "stable",
          platform: "mac",
          endpointId,
          identityGeneration: 1,
          pairingEnabled: true,
          capabilities: [],
          pathHints: [],
        },
        now: NOW,
      }));
    };

    const legacy = await register(randomUUID(), "legacy", "37".repeat(32));
    const tagOnly = await register(
      randomUUID(),
      "mac:stable",
      "38".repeat(32),
    );
    const adopted = await register(
      randomUUID(),
      "mac:com.cmuxterm.app",
      "39".repeat(32),
    );

    expect(adopted.binding.id).toBe(legacy.binding.id);
    expect(tagOnly.binding.id).toBe(legacy.binding.id);
    expect(adopted.created).toBe(false);
    const rows = await requiredSql()<Array<{
      id: string;
      clientNamespace: string;
    }>>`
      select id, client_namespace as "clientNamespace"
      from iroh_endpoint_bindings
      where user_id = ${userId}
    `;
    expect(rows).toEqual([{
      id: legacy.binding.id,
      clientNamespace: "mac:com.cmuxterm.app",
    }]);
  });

  dbTest("drains a migrated legacy revocation before namespace adoption", async () => {
    const repo = requiredRepository();
    const userId = "user-legacy-namespace-revocation";
    const [legacy] = await requiredSql()<Array<{ id: string }>>`
      insert into iroh_endpoint_bindings (
        user_id,
        device_uuid,
        app_instance_id,
        client_namespace,
        tag,
        platform,
        endpoint_id,
        identity_generation
      ) values (
        ${userId},
        ${randomUUID()},
        ${randomUUID()},
        'legacy',
        'stable',
        'ios',
        ${"39".repeat(32)},
        1
      )
      returning id
    `;
    if (!legacy) throw new Error("legacy binding insert failed");

    const revoked = await Effect.runPromise(repo.revokeBinding({
      userId,
      bindingId: legacy.id,
      clientNamespace: "dev.cmux.app.internal",
      now: NOW,
    }));

    expect(revoked).toEqual({ revoked: true, accountRevision: 1 });
    const [stored] = await requiredSql()<Array<{
      revokedAt: Date | null;
      revokedReason: string | null;
    }>>`
      select
        revoked_at as "revokedAt",
        revoked_reason as "revokedReason"
      from iroh_endpoint_bindings
      where id = ${legacy.id}
    `;
    expect(stored?.revokedAt).toEqual(NOW);
    expect(stored?.revokedReason).toBe("user_requested");
  });

  dbTest("isolates iOS discovery while Mac admission sees iOS peers", async () => {
    const repo = requiredRepository();
    const userId = "user-namespace-discovery";
    const rows = await requiredSql()<Array<{
      id: string;
      clientNamespace: string;
    }>>`
      insert into iroh_endpoint_bindings (
        user_id,
        device_uuid,
        app_instance_id,
        client_namespace,
        tag,
        platform,
        endpoint_id,
        identity_generation
      ) values
        (
          ${userId},
          ${randomUUID()},
          ${randomUUID()},
          'dev.cmux.app.internal',
          'stable',
          'ios',
          ${"3a".repeat(32)},
          1
        ),
        (
          ${userId},
          ${randomUUID()},
          ${randomUUID()},
          'dev.cmux.app.demo',
          'stable',
          'ios',
          ${"3b".repeat(32)},
          1
        ),
        (
          ${userId},
          ${randomUUID()},
          ${randomUUID()},
          'mac:stable',
          'stable',
          'mac',
          ${"3c".repeat(32)},
          1
        )
      returning id, client_namespace as "clientNamespace"
    `;
    const idByNamespace = new Map(
      rows.map((row) => [row.clientNamespace, row.id]),
    );

    const demo = await Effect.runPromise(repo.discoverySnapshot({
      userId,
      clientNamespace: "dev.cmux.app.demo",
      callerBindingId: idByNamespace.get("dev.cmux.app.demo")!,
      callerPlatform: "ios",
      now: NOW,
    }));
    expect(demo.bindings.map((row) => row.id).sort()).toEqual([
      idByNamespace.get("dev.cmux.app.demo"),
      idByNamespace.get("mac:stable"),
    ].sort());

    const mac = await Effect.runPromise(repo.discoverySnapshot({
      userId,
      clientNamespace: "mac:stable",
      callerBindingId: idByNamespace.get("mac:stable")!,
      callerPlatform: "mac",
      now: NOW,
    }));
    expect(mac.bindings.map((row) => row.id).sort()).toEqual(
      [...idByNamespace.values()].sort(),
    );
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
      clientNamespace: "legacy",
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
        clientNamespace: "legacy",
        tag: "stable",
        platform: "mac",
        endpointId,
        identityGeneration: 1,
        pairingEnabled: true,
        capabilities: [],
        pathHints,
      },
      now: NOW,
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
        clientNamespace: "legacy",
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

  dbTest("reincarnates the (user, device, tag) slot with a fresh id when the platform changes", async () => {
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
          clientNamespace: "legacy",
          tag: "stable",
          platform,
          endpointId,
          identityGeneration: 1,
          pairingEnabled: platform === "mac",
          capabilities: [],
          pathHints: [],
        },
        now,
      });
    };

    const first = await Effect.runPromise(await register("mac", "5", NOW));
    const second = await Effect.runPromise(await register(
      "ios",
      "6",
      new Date(NOW.getTime() + 1_000),
    ));
    // Platform is a peer-signed admission field, so a mac->ios change on the same
    // slot must NOT overwrite the live id: a still-valid grant signed against the
    // old platform would then mismatch this binding and the host would record the
    // id in its permanent denial set (the ABA wedge). The slot reincarnates
    // instead: the old row is revoked and a fresh binding id is minted. This is
    // safe even though the endpoint id is unchanged, because the revoke commits
    // before the insert, so the active-endpoint unique index never sees two live
    // rows for one endpoint.
    expect(second.created).toBe(true);
    expect(second.binding.id).not.toBe(first.binding.id);
    const [previous] = await requiredSql()<Array<{ revokedAt: Date | null }>>`
      select revoked_at as "revokedAt"
      from iroh_endpoint_bindings
      where id = ${first.binding.id}
    `;
    expect(previous?.revokedAt).not.toBeNull();
    const [state] = await requiredSql()<Array<{
      platform: string;
      pairingEnabled: boolean;
      active: string;
    }>>`
      select
        platform,
        pairing_enabled as "pairingEnabled",
        (select count(*)::text from iroh_endpoint_bindings
          where user_id = ${userId} and revoked_at is null) as active
      from iroh_endpoint_bindings
      where id = ${second.binding.id}
    `;
    expect(state).toEqual({ platform: "ios", pairingEnabled: false, active: "1" });
  });

  dbTest("enforces globally unique active EndpointIDs", async () => {
    const appInstanceId = randomUUID();
    const endpointId = "40".repeat(32);
    await insertBinding({ userId: "user-a", appInstanceId, endpointId });
    await expectPostgresError(insertBinding({ userId: "user-b", endpointId }), "23505");
    // The app instance id is no longer a uniqueness key: two active bindings may
    // share it (the slot is keyed on user + device + tag instead).
    await insertBinding({ userId: "user-b", appInstanceId, endpointId: "41".repeat(32) });
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

  dbTest("rejects a second active binding for the same (user, device, tag) slot", async () => {
    const deviceUuid = randomUUID();
    await insertBinding({
      userId: "user-slot-unique",
      deviceUuid,
      endpointId: "44".repeat(32),
    });
    // insertBinding always writes tag 'stable', so a second active row for the
    // same (user, device, tag) must trip the slot unique index that replaced the
    // old per-app-instance one.
    await expectPostgresError(
      insertBinding({
        userId: "user-slot-unique",
        deviceUuid,
        endpointId: "45".repeat(32),
      }),
      "23505",
    );
  });

  dbTest("re-keys a reinstalled slot onto a fresh binding id and frees its old endpoint", async () => {
    const repo = requiredRepository();
    const userId = "user-slot-reinstall";
    const deviceId = randomUUID();
    const firstEndpoint = "46".repeat(32);
    const rotatedEndpoint = "47".repeat(32);

    const register = async (input: {
      appInstanceId: string;
      endpointId: string;
      tag: string;
      identityGeneration: number;
      suffix: string;
      now: Date;
    }) => {
      const nonceHash = input.suffix.repeat(64);
      const challenge = await Effect.runPromise(repo.issueChallenge({
        userId,
        deviceUuid: deviceId,
        appInstanceId: input.appInstanceId,
        tag: input.tag,
        endpointId: input.endpointId,
        identityGeneration: input.identityGeneration,
        payloadSha256: `${input.suffix}${"0".repeat(63)}`,
        nonceHash,
        now: input.now,
        expiresAt: new Date(input.now.getTime() + 5 * 60 * 1_000),
      }));
      return Effect.runPromise(repo.consumeChallengeAndRegister({
        userId,
        challengeId: challenge.id,
        nonceHash,
        payload: {
          route_contract_version: 1,
          deviceId,
          appInstanceId: input.appInstanceId,
          clientNamespace: "legacy",
          tag: input.tag,
          platform: "ios",
          endpointId: input.endpointId,
          identityGeneration: input.identityGeneration,
          pairingEnabled: true,
          capabilities: [],
          pathHints: [],
        },
        now: input.now,
      }));
    };

    const firstApp = randomUUID();
    const first = await register({
      appInstanceId: firstApp,
      endpointId: firstEndpoint,
      tag: "stable",
      identityGeneration: 2,
      suffix: "1",
      now: NOW,
    });
    expect(first.created).toBe(true);

    // Reinstall: fresh app instance, rotated endpoint, generation reset to 1.
    // The rotated key is a new incarnation, so the slot is re-keyed onto a BRAND
    // NEW binding id (never the retired one) to dodge the ABA wedge where a host
    // that denied the old id would keep denying a resurrected same-id row. The old
    // row is soft-revoked, not deleted, and its live pair grants are revoked: the
    // client's held grant JWS still names the dead endpoint, so it must re-pair.
    const reinstallApp = randomUUID();
    const reinstalled = await register({
      appInstanceId: reinstallApp,
      endpointId: rotatedEndpoint,
      tag: "stable",
      identityGeneration: 1,
      suffix: "2",
      now: new Date(NOW.getTime() + 1_000),
    });
    expect(reinstalled.created).toBe(true);
    expect(reinstalled.binding.id).not.toBe(first.binding.id);
    expect(reinstalled.binding.endpointId).toBe(rotatedEndpoint);
    expect(reinstalled.binding.appInstanceId).toBe(reinstallApp);
    expect(reinstalled.binding.identityGeneration).toBe(1);

    // A different tag on the same device is a distinct slot, not a replacement.
    const secondTag = await register({
      appInstanceId: randomUUID(),
      endpointId: "48".repeat(32),
      tag: "nightly",
      identityGeneration: 1,
      suffix: "3",
      now: NOW,
    });
    expect(secondTag.created).toBe(true);
    expect(secondTag.binding.id).not.toBe(first.binding.id);

    const [state] = await requiredSql()<Array<{
      active: string;
      slotBindingId: string;
      slotEndpoint: string;
      oldRevokedReason: string | null;
      oldEndpointFree: boolean;
    }>>`
      select
        (select count(*)::text from iroh_endpoint_bindings
          where user_id = ${userId} and revoked_at is null) as active,
        (select id from iroh_endpoint_bindings
          where user_id = ${userId} and device_uuid = ${deviceId}
            and tag = 'stable' and revoked_at is null) as "slotBindingId",
        (select endpoint_id from iroh_endpoint_bindings
          where user_id = ${userId} and device_uuid = ${deviceId}
            and tag = 'stable' and revoked_at is null) as "slotEndpoint",
        (select revoked_reason from iroh_endpoint_bindings
          where id = ${first.binding.id}) as "oldRevokedReason",
        not exists(
          select 1 from iroh_endpoint_bindings
          where endpoint_id = ${firstEndpoint} and revoked_at is null
        ) as "oldEndpointFree"
    `;
    expect(state).toEqual({
      active: "2",
      slotBindingId: reinstalled.binding.id,
      slotEndpoint: rotatedEndpoint,
      oldRevokedReason: "slot_reincarnated",
      oldEndpointFree: true,
    });
  });

  dbTest("rejects a stale heartbeat challenge that completes after a newer one", async () => {
    const repo = requiredRepository();
    const userId = "user-slot-reversed-heartbeat";
    const deviceId = randomUUID();
    const endpoint = "5a".repeat(32);
    const tag = "stable";

    // Every registration here is a heartbeat/refresh of ONE live slot: the
    // signed fields (endpoint, platform, generation) never change, so each takes
    // the in-place update path. Only appInstanceId (a mutable field) differs, so
    // whichever challenge lands last dictates the slot's stored appInstanceId.
    const prepare = async (input: { appInstanceId: string; suffix: string; now: Date }) => {
      const nonceHash = input.suffix.repeat(64);
      const challenge = await Effect.runPromise(repo.issueChallenge({
        userId,
        deviceUuid: deviceId,
        appInstanceId: input.appInstanceId,
        clientNamespace: "legacy",
        tag,
        endpointId: endpoint,
        identityGeneration: 1,
        payloadSha256: `${input.suffix}${"0".repeat(63)}`,
        nonceHash,
        now: input.now,
        expiresAt: new Date(input.now.getTime() + 5 * 60 * 1_000),
      }));
      return { id: challenge.id, nonceHash, appInstanceId: input.appInstanceId };
    };

    const register = (
      prepared: { id: string; nonceHash: string; appInstanceId: string },
      now: Date,
    ) => repo.consumeChallengeAndRegister({
      userId,
      challengeId: prepared.id,
      nonceHash: prepared.nonceHash,
      payload: {
        route_contract_version: 1,
        deviceId,
        appInstanceId: prepared.appInstanceId,
        clientNamespace: "legacy",
        tag,
        platform: "ios",
        endpointId: endpoint,
        identityGeneration: 1,
        pairingEnabled: true,
        capabilities: [],
        pathHints: [],
      },
      now,
    });

    // Establish the slot at t0.
    const initial = await Effect.runPromise(
      register(await prepare({ appInstanceId: randomUUID(), suffix: "1", now: NOW }), NOW),
    );
    expect(initial.created).toBe(true);

    // Two heartbeat challenges for the same slot, minted in order: OLDER at
    // t0+1s, NEWER at t0+2s. Both are outstanding before either is consumed.
    const olderApp = randomUUID();
    const newerApp = randomUUID();
    const older = await prepare({ appInstanceId: olderApp, suffix: "2", now: new Date(NOW.getTime() + 1_000) });
    const newer = await prepare({ appInstanceId: newerApp, suffix: "3", now: new Date(NOW.getTime() + 2_000) });

    // The NEWER challenge lands first and refreshes the slot.
    const newerResult = await Effect.runPromise(register(newer, new Date(NOW.getTime() + 2_500)));
    expect(newerResult.created).toBe(false);
    expect(newerResult.binding.appInstanceId).toBe(newerApp);

    // The OLDER challenge, delayed, completes second. It was minted before the
    // newer registration landed, so it must be rejected as superseded rather
    // than clobbering the newer incarnation's mutable fields back to the stale
    // appInstanceId. This only holds if an applied heartbeat advances the slot's
    // registration high-water mark.
    const stale = await Effect.runPromiseExit(register(older, new Date(NOW.getTime() + 3_000)));
    expect(stale._tag).toBe("Failure");
    const causeError = stale._tag === "Failure"
      ? Option.getOrUndefined(Cause.failureOption(stale.cause))
      : undefined;
    expect(causeError).toMatchObject({
      _tag: "IrohConflictError",
      code: "challenge_superseded",
    });

    // The slot still reflects the NEWER heartbeat, never the older one.
    const [row] = await requiredSql()<Array<{ appInstanceId: string }>>`
      select app_instance_id as "appInstanceId"
      from iroh_endpoint_bindings
      where user_id = ${userId} and device_uuid = ${deviceId}
        and tag = ${tag} and revoked_at is null
    `;
    expect(row?.appInstanceId).toBe(newerApp);
  });

  dbTest("rejects a stale challenge that completes after a newer one on a fresh slot", async () => {
    const repo = requiredRepository();
    const userId = "user-slot-reversed-insert";
    const deviceId = randomUUID();
    const endpoint = "5b".repeat(32);
    const tag = "stable";

    // Same signed fields (endpoint, platform, generation) throughout, so the
    // second landing takes the in-place update path. Only appInstanceId differs.
    // The difference from the heartbeat case: NO row exists yet when both
    // challenges are minted, so the FIRST landing goes through the insert path.
    // If the insert stamps registeredAt with its own wall-clock landing time
    // instead of its challenge mint time, an older challenge that happens to
    // land first sets the high-water mark above a newer outstanding challenge's
    // mint time, and the genuinely newer registration is wrongly superseded.
    const prepare = async (input: { appInstanceId: string; suffix: string; now: Date }) => {
      const nonceHash = input.suffix.repeat(64);
      const challenge = await Effect.runPromise(repo.issueChallenge({
        userId,
        deviceUuid: deviceId,
        appInstanceId: input.appInstanceId,
        tag,
        endpointId: endpoint,
        identityGeneration: 1,
        payloadSha256: `${input.suffix}${"0".repeat(63)}`,
        nonceHash,
        now: input.now,
        expiresAt: new Date(input.now.getTime() + 5 * 60 * 1_000),
      }));
      return { id: challenge.id, nonceHash, appInstanceId: input.appInstanceId };
    };

    const register = (
      prepared: { id: string; nonceHash: string; appInstanceId: string },
      now: Date,
    ) => repo.consumeChallengeAndRegister({
      userId,
      challengeId: prepared.id,
      nonceHash: prepared.nonceHash,
      payload: {
        route_contract_version: 1,
        deviceId,
        appInstanceId: prepared.appInstanceId,
        clientNamespace: "legacy",
        tag,
        platform: "ios",
        endpointId: endpoint,
        identityGeneration: 1,
        pairingEnabled: true,
        capabilities: [],
        pathHints: [],
      },
      now,
    });

    // Two challenges for a slot that does not exist yet, minted in order:
    // OLDER at t0+1s, NEWER at t0+2s. Both outstanding before either is consumed.
    const olderApp = randomUUID();
    const newerApp = randomUUID();
    const older = await prepare({ appInstanceId: olderApp, suffix: "2", now: new Date(NOW.getTime() + 1_000) });
    const newer = await prepare({ appInstanceId: newerApp, suffix: "3", now: new Date(NOW.getTime() + 2_000) });

    // The OLDER challenge lands first and CREATES the slot via the insert path.
    const olderResult = await Effect.runPromise(register(older, new Date(NOW.getTime() + 2_500)));
    expect(olderResult.created).toBe(true);
    expect(olderResult.binding.appInstanceId).toBe(olderApp);

    // The NEWER challenge, minted after the older one but before the slot
    // existed, completes second. It is genuinely newer, so it must refresh the
    // slot in place, not be rejected. This only holds if the insert stamped the
    // high-water mark from the older challenge's MINT time (t0+1s), leaving the
    // newer challenge's mint time (t0+2s) above it.
    const newerResult = await Effect.runPromise(register(newer, new Date(NOW.getTime() + 3_000)));
    expect(newerResult.created).toBe(false);
    expect(newerResult.binding.appInstanceId).toBe(newerApp);

    // The slot reflects the NEWER registration.
    const [row] = await requiredSql()<Array<{ appInstanceId: string }>>`
      select app_instance_id as "appInstanceId"
      from iroh_endpoint_bindings
      where user_id = ${userId} and device_uuid = ${deviceId}
        and tag = ${tag} and revoked_at is null
    `;
    expect(row?.appInstanceId).toBe(newerApp);
  });

  dbTest("rejects a stale challenge minted in the same millisecond as the applied one", async () => {
    // 9071 review finding 2: the register gate is strict (`createdAt <
    // registeredAt`), and challenge createdAt is a millisecond wall clock, so
    // two serialized mints CAN tie. Without total ordering at mint time, the
    // older-of-two-equal challenges completes after the newer and passes the
    // gate, reversing the order the gate exists to enforce. Minting now bumps
    // a tying createdAt strictly above the slot's latest challenge, so the
    // delayed twin must be rejected as superseded.
    const repo = requiredRepository();
    const userId = "user-slot-equal-millis";
    const deviceId = randomUUID();
    const endpoint = "5c".repeat(32);
    const tag = "stable";

    const prepare = async (input: { appInstanceId: string; suffix: string; now: Date }) => {
      const nonceHash = input.suffix.repeat(64);
      const challenge = await Effect.runPromise(repo.issueChallenge({
        userId,
        deviceUuid: deviceId,
        appInstanceId: input.appInstanceId,
        tag,
        endpointId: endpoint,
        identityGeneration: 1,
        payloadSha256: `${input.suffix}${"0".repeat(63)}`,
        nonceHash,
        now: input.now,
        expiresAt: new Date(input.now.getTime() + 5 * 60 * 1_000),
      }));
      return { id: challenge.id, nonceHash, appInstanceId: input.appInstanceId };
    };
    const register = (
      prepared: { id: string; nonceHash: string; appInstanceId: string },
      now: Date,
    ) => repo.consumeChallengeAndRegister({
      userId,
      challengeId: prepared.id,
      nonceHash: prepared.nonceHash,
      payload: {
        route_contract_version: 1,
        deviceId,
        appInstanceId: prepared.appInstanceId,
        clientNamespace: "legacy",
        tag,
        platform: "ios",
        endpointId: endpoint,
        identityGeneration: 1,
        pairingEnabled: true,
        capabilities: [],
        pathHints: [],
      },
      now,
    });

    // Establish the slot, then mint two challenges with the SAME wall-clock
    // input. Serialized issuance must still order them.
    const initial = await prepare({ appInstanceId: randomUUID(), suffix: "1", now: NOW });
    expect((await Effect.runPromise(register(initial, new Date(NOW.getTime() + 500)))).created).toBe(true);

    const tieInstant = new Date(NOW.getTime() + 1_000);
    const olderApp = randomUUID();
    const newerApp = randomUUID();
    const older = await prepare({ appInstanceId: olderApp, suffix: "2", now: tieInstant });
    const newer = await prepare({ appInstanceId: newerApp, suffix: "3", now: tieInstant });

    // The NEWER twin lands first and refreshes the slot.
    const newerResult = await Effect.runPromise(register(newer, new Date(NOW.getTime() + 2_000)));
    expect(newerResult.created).toBe(false);
    expect(newerResult.binding.appInstanceId).toBe(newerApp);

    // The OLDER twin, delayed, must be rejected — not clobber the newer state.
    const stale = await Effect.runPromiseExit(register(older, new Date(NOW.getTime() + 3_000)));
    expect(stale._tag).toBe("Failure");
    const causeError = stale._tag === "Failure"
      ? Option.getOrUndefined(Cause.failureOption(stale.cause))
      : undefined;
    expect(causeError).toMatchObject({
      _tag: "IrohConflictError",
      code: "challenge_superseded",
    });

    const [row] = await requiredSql()<Array<{ appInstanceId: string }>>`
      select app_instance_id as "appInstanceId"
      from iroh_endpoint_bindings
      where user_id = ${userId} and device_uuid = ${deviceId}
        and tag = ${tag} and revoked_at is null
    `;
    expect(row?.appInstanceId).toBe(newerApp);
  });

  dbTest("revokes a retired incarnation's pair grants instead of reassigning them", async () => {
    const repo = requiredRepository();
    const initiatorUser = "user-rekey-grant-initiator";
    const deviceId = randomUUID();
    const firstEndpoint = "60".repeat(32);
    const rotatedEndpoint = "61".repeat(32);

    const registerInitiator = async (input: {
      endpointId: string;
      suffix: string;
      now: Date;
    }) => {
      const nonceHash = input.suffix.repeat(64);
      const appInstanceId = randomUUID();
      const challenge = await Effect.runPromise(repo.issueChallenge({
        userId: initiatorUser,
        deviceUuid: deviceId,
        appInstanceId,
        tag: "stable",
        endpointId: input.endpointId,
        identityGeneration: 1,
        payloadSha256: `${input.suffix}${"0".repeat(63)}`,
        nonceHash,
        now: input.now,
        expiresAt: new Date(input.now.getTime() + 5 * 60 * 1_000),
      }));
      return Effect.runPromise(repo.consumeChallengeAndRegister({
        userId: initiatorUser,
        challengeId: challenge.id,
        nonceHash,
        payload: {
          route_contract_version: 1,
          deviceId,
          appInstanceId,
          clientNamespace: "legacy",
          tag: "stable",
          platform: "ios",
          endpointId: input.endpointId,
          identityGeneration: 1,
          pairingEnabled: true,
          capabilities: [],
          pathHints: [],
        },
        now: input.now,
      }));
    };

    const initiator = await registerInitiator({ endpointId: firstEndpoint, suffix: "6", now: NOW });
    const acceptorId = await insertBinding({
      userId: initiatorUser,
      deviceUuid: randomUUID(),
      platform: "mac",
      endpointId: "62".repeat(32),
    });

    const insertGrant = async (revokedAt: Date | null) => {
      const [row] = await requiredSql()<Array<{ id: string }>>`
        insert into iroh_pair_grant_issuances (
          user_id, jti, initiator_binding_id, acceptor_binding_id, signing_key_id,
          alpn, scope, issued_at, not_before, expires_at, revoked_at
        ) values (
          ${initiatorUser}, ${randomUUID()}, ${initiator.binding.id}, ${acceptorId}, 'current',
          'cmux/mobile/1', 'cmux.mobile.attach',
          ${NOW}, ${NOW}, ${new Date(NOW.getTime() + 7 * 24 * 60 * 60 * 1_000)}, ${revokedAt}
        ) returning id::text
      `;
      if (!row) throw new Error("grant insert returned no row");
      return row.id;
    };

    // A live pair grant anchored to the initiator's first incarnation, plus an
    // already-revoked grant on the same id. iroh_pair_grant_issuances is an
    // audit-only ledger of compact JWS tokens that were returned once and name the
    // OLD binding id and endpoint; reassigning the foreign key could not rewrite a
    // client's held token, so both grants must stay attached to the retired row.
    const liveGrantId = await insertGrant(null);
    const staleGrantId = await insertGrant(NOW);

    const reinstalled = await registerInitiator({
      endpointId: rotatedEndpoint,
      suffix: "7",
      now: new Date(NOW.getTime() + 1_000),
    });
    expect(reinstalled.binding.id).not.toBe(initiator.binding.id);

    const [grants] = await requiredSql()<Array<{
      liveInitiator: string;
      liveRevoked: boolean;
      staleInitiator: string;
      staleRevoked: boolean;
    }>>`
      select
        (select initiator_binding_id::text from iroh_pair_grant_issuances
          where id = ${liveGrantId}) as "liveInitiator",
        (select revoked_at is not null from iroh_pair_grant_issuances
          where id = ${liveGrantId}) as "liveRevoked",
        (select initiator_binding_id::text from iroh_pair_grant_issuances
          where id = ${staleGrantId}) as "staleInitiator",
        (select revoked_at is not null from iroh_pair_grant_issuances
          where id = ${staleGrantId}) as "staleRevoked"
    `;
    // Both grants stay attached to the retired incarnation (audit-accurate), and
    // the previously-live grant is now revoked. Re-keying forces a re-pair because
    // the held token names the dead endpoint, so no grant can carry authorization
    // onto the new id.
    expect(grants?.liveInitiator).toBe(initiator.binding.id);
    expect(grants?.liveRevoked).toBe(true);
    expect(grants?.staleInitiator).toBe(initiator.binding.id);
    expect(grants?.staleRevoked).toBe(true);
  });

  dbTest("registers and discovers more than 256 active bindings across bounded pages", async () => {
    const repo = requiredRepository();
    const userId = "user-unbounded-bindings";

    await requiredSql()`
      insert into iroh_endpoint_bindings (
        user_id, device_uuid, app_instance_id, tag, platform, endpoint_id,
        identity_generation, pairing_enabled, capabilities, path_hints,
        last_seen_at, registered_at
      )
      select
        ${userId}, gen_random_uuid(), gen_random_uuid(), 'stable', 'ios',
        lpad(to_hex(gs), 64, '0'), 1, true, '[]'::jsonb, '[]'::jsonb,
        ${NOW}::timestamptz + (gs * interval '1 second'),
        ${NOW}::timestamptz + (gs * interval '1 second')
      from generate_series(1, 300) as gs
    `;

    const deviceId = randomUUID();
    const appInstanceId = randomUUID();
    const nonceHash = "8".repeat(64);
    const challenge = await Effect.runPromise(repo.issueChallenge({
      userId,
      deviceUuid: deviceId,
      appInstanceId,
      tag: "stable",
      endpointId: "c1".repeat(32),
      identityGeneration: 1,
      payloadSha256: `8${"0".repeat(63)}`,
      nonceHash,
      now: new Date(NOW.getTime() + 301_000),
      expiresAt: new Date(NOW.getTime() + 601_000),
    }));
    const registration = await Effect.runPromise(repo.consumeChallengeAndRegister({
      userId,
      challengeId: challenge.id,
      nonceHash,
      payload: {
        route_contract_version: 1,
        deviceId,
        appInstanceId,
        clientNamespace: "legacy",
        tag: "stable",
        platform: "ios",
        endpointId: "c1".repeat(32),
        identityGeneration: 1,
        pairingEnabled: true,
        capabilities: [],
        pathHints: [],
      },
      now: new Date(NOW.getTime() + 301_000),
    }));
    expect(registration.created).toBe(true);

    const pageCounts: number[] = [];
    const bindingIds = new Set<string>();
    let cursor: { generation: number; afterBindingId: string } | undefined;
    do {
      const page = await Effect.runPromise(repo.discoveryPage({
        userId,
        now: new Date(NOW.getTime() + 302_000),
        pageSize: 128,
        ...(cursor ? { cursor } : {}),
      }));
      pageCounts.push(page.bindings.length);
      page.bindings.forEach((binding) => bindingIds.add(binding.id));
      cursor = page.nextCursor ?? undefined;
    } while (cursor);

    expect(pageCounts).toEqual([128, 128, 45]);
    expect(bindingIds.size).toBe(301);
    const complete = await Effect.runPromise(repo.discoverySnapshot({
      userId,
      now: new Date(NOW.getTime() + 302_000),
    }));
    expect(complete.bindings).toHaveLength(301);
    expect(complete.accountRevision).toBe(registration.accountRevision);
  });

  dbTest("filters scoped discovery in the authoritative SQL snapshot", async () => {
    const repo = requiredRepository();
    const userId = "user-scoped-discovery";
    const deviceId = randomUUID();
    const appInstanceId = randomUUID();
    const localId = await insertBinding({
      userId,
      deviceUuid: deviceId,
      appInstanceId,
      endpointId: "d1".repeat(32),
      platform: "ios",
      tag: "stable",
    });
    const eligibleMacId = await insertBinding({
      userId,
      endpointId: "d2".repeat(32),
      platform: "mac",
      tag: "FeatureA",
      pairingEnabled: true,
    });
    await insertBinding({
      userId,
      endpointId: "d3".repeat(32),
      platform: "mac",
      tag: "other",
      pairingEnabled: true,
    });
    await insertBinding({
      userId,
      endpointId: "d4".repeat(32),
      platform: "mac",
      tag: "default",
      pairingEnabled: false,
    });
    await insertBinding({
      userId,
      endpointId: "d5".repeat(32),
      platform: "ios",
      tag: "stable",
    });
    const revokedMacId = await insertBinding({
      userId,
      endpointId: "d6".repeat(32),
      platform: "mac",
      tag: "nightly",
      pairingEnabled: true,
    });
    await requiredSql()`
      update iroh_endpoint_bindings
      set revoked_at = ${NOW}, revoked_reason = 'test'
      where id = ${revokedMacId}
    `;
    await insertBinding({
      userId: "other-user",
      endpointId: "d7".repeat(32),
      platform: "mac",
      tag: "default",
      pairingEnabled: true,
    });

    const snapshot = await Effect.runPromise(repo.discoverySnapshot({
      userId,
      now: NOW,
      scope: {
        localBinding: {
          deviceId,
          appInstanceId,
          tag: "stable",
          platform: "ios",
        },
        peerBindings: {
          platform: "mac",
          tags: ["featurea", "nightly"],
          pairingEnabled: true,
        },
      },
    }));

    expect(snapshot.bindings.map((binding) => binding.id)).toEqual(
      [localId, eligibleMacId].sort(),
    );
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
    }))).toEqual({ revoked: true, accountRevision: 1 });

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

    const initial = await Effect.runPromise(repo.discoveryPage({
      userId,
      now: NOW,
      pageSize: 256,
    }));
    const otherInitial = await Effect.runPromise(repo.discoveryPage({
      userId: "user-lan-other",
      now: NOW,
      pageSize: 256,
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
    }))).toEqual({ revoked: true, accountRevision: 1 });
    const afterFirstRevoke = await Effect.runPromise(repo.discoveryPage({
      userId,
      now: NOW,
      pageSize: 256,
    }));
    expect(afterFirstRevoke.lanDiscoveryGeneration).toBe(2);
    expect(afterFirstRevoke.bindings.map((binding) => binding.id)).toEqual([secondBindingId]);
    expect(await Effect.runPromise(repo.revokeBinding({
      userId,
      bindingId: firstBindingId,
      now: new Date(NOW.getTime() + 60_000),
    }))).toEqual({ revoked: true, accountRevision: 1 });
    const [retriedBinding] = await requiredSql()<Array<{ revokedAt: Date }>>`
      select revoked_at as "revokedAt"
      from iroh_endpoint_bindings
      where id = ${firstBindingId}
    `;
    expect(retriedBinding?.revokedAt).toEqual(NOW);
    expect((await Effect.runPromise(repo.discoveryPage({
      userId,
      now: NOW,
      pageSize: 256,
    }))).lanDiscoveryGeneration).toBe(2);
    expect(await Effect.runPromise(repo.revokeBinding({
      userId: "user-lan-other",
      bindingId: firstBindingId,
      now: NOW,
    }))).toEqual({ revoked: false, accountRevision: 0 });
    expect(await Effect.runPromise(repo.revokeBinding({
      userId,
      bindingId: randomUUID(),
      now: NOW,
    }))).toEqual({ revoked: false, accountRevision: 1 });

    let concurrentSnapshot: ReturnType<typeof Effect.runPromise> | undefined;
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
        set lan_discovery_generation = lan_discovery_generation + 1,
            route_revision = route_revision + 1,
            updated_at = ${NOW}
        where user_id = ${userId}
      `;
      concurrentSnapshot = Effect.runPromise(repo.discoverySnapshot({
        userId,
        now: NOW,
      }));
      await waitForAdvisoryLockWaiter();
    });
    if (!concurrentSnapshot) throw new Error("concurrent discovery was not started");
    const afterConcurrentRevoke = await concurrentSnapshot;
    expect(afterConcurrentRevoke).toMatchObject({
      lanDiscoveryGeneration: 3,
      accountRevision: 2,
      bindings: [],
    });
    const otherAfter = await Effect.runPromise(repo.discoveryPage({
      userId: "user-lan-other",
      now: NOW,
      pageSize: 256,
    }));
    expect(otherAfter).toMatchObject({
      lanDiscoveryGeneration: 1,
      bindings: [{ id: otherBindingId }],
    });
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
    // Two distinct slots on the same physical device: same device_uuid, different
    // tags. The same-device pair-grant guard keys on device_uuid alone, so it
    // must still reject these even though they are separate (user, device, tag)
    // slots under the re-keyed binding model.
    const initiatorId = await insertBinding({
      userId,
      deviceUuid,
      platform: "ios",
      tag: "stable",
      endpointId: "54".repeat(32),
    });
    const acceptorId = await insertBinding({
      userId,
      deviceUuid,
      platform: "mac",
      tag: "nightly",
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
    }))).toEqual({ revoked: true, accountRevision: 1 });
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
  readonly tag?: string;
  readonly pairingEnabled?: boolean;
  readonly pathHints?: unknown[];
}): Promise<string> {
  const [row] = await requiredSql()<Array<{ id: string }>>`
    insert into iroh_endpoint_bindings (
      user_id, device_uuid, app_instance_id, tag, platform, endpoint_id,
      identity_generation, pairing_enabled, capabilities, path_hints,
      path_hints_next_expiry
    ) values (
      ${input.userId}, ${input.deviceUuid ?? randomUUID()}, ${input.appInstanceId ?? randomUUID()}, ${input.tag ?? "stable"},
      ${input.platform ?? "mac"}, ${input.endpointId}, 1,
      ${input.pairingEnabled ?? true}, '[]'::jsonb,
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
