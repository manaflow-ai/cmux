import { afterAll, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { randomUUID } from "node:crypto";
import * as Effect from "effect/Effect";
import postgres, { type Sql } from "postgres";
import { closeCloudDbForTests } from "../db/client";
import {
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
      iroh_account_security_states
    restart identity cascade
  `;
});

afterAll(async () => {
  await closeCloudDbForTests();
  await sql?.end();
});

describe("Iroh trust broker database behavior", () => {
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
      deviceLimitOverrideAllowed: false,
    }));
    const results = await Promise.allSettled([register(), register()]);
    expect(results.filter((result) => result.status === "fulfilled")).toHaveLength(1);
    expect(results.filter((result) => result.status === "rejected")).toHaveLength(1);
    const [{ bindings, consumed }] = await requiredSql()<Array<{ bindings: string; consumed: string }>>`
      select
        (select count(*)::text from iroh_endpoint_bindings) as bindings,
        (select count(*)::text from iroh_registration_challenges where consumed_at is not null) as consumed
    `;
    expect({ bindings, consumed }).toEqual({ bindings: "1", consumed: "1" });
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
    const reserve = () => Effect.runPromise(repo.recordPairGrant({
      userId: "user-pair",
      jti: randomUUID(),
      initiatorBindingId: initiatorId,
      acceptorBindingId: acceptorId,
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
      identity_generation, pairing_enabled, capabilities, path_hints
    ) values (
      ${input.userId}, ${randomUUID()}, ${input.appInstanceId ?? randomUUID()}, 'stable',
      ${input.platform ?? "mac"}, ${input.endpointId}, 1, true, '[]'::jsonb,
      ${requiredSql().json((input.pathHints ?? []) as never)}
    ) returning id::text
  `;
  if (!row) throw new Error("binding insert returned no row");
  return row.id;
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
