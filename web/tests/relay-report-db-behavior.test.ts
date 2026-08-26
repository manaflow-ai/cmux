// Database-backed tests of the relay attach-report registry behavior behind
// POST /api/relay/report: the route tests fake the application, so the
// ordering guards, the custom-relay trust join, revocation, and the
// discovery read that serves the attach-derived hint to a phone are proven
// here against Postgres. Gated like tests/iroh-db-behavior.test.ts.

import { afterAll, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { generateKeyPairSync, randomUUID } from "node:crypto";
import * as Effect from "effect/Effect";
import postgres, { type Sql } from "postgres";

import { closeCloudDbForTests } from "../db/client";
import type { IrohTrustBrokerConfigShape } from "../services/iroh/config";
import type { IrohPathHint } from "../services/iroh/model";
import {
  IrohRepository,
  IrohRepositoryLive,
  type IrohRepositoryShape,
} from "../services/iroh/repository";
import { makeIrohTrustBroker } from "../services/iroh/trustBroker";
import {
  applyRelayAttachReport,
  closeRelayReportClientForTests,
  type RelayAttachReport,
} from "../services/relay/report";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;

const USER_ID = "user-report";
const ENDPOINT_ID = "ab".repeat(32);
const MANAGED_HOSTNAME = "usc1.relay.cmux.dev";
const MANAGED_URL = "https://usc1.relay.cmux.dev/";
const OTHER_MANAGED_HOSTNAME = "euw4.relay.cmux.dev";
const CUSTOM_HOSTNAME = "relay.corp.example";
const CUSTOM_URL = "https://relay.corp.example:8443/";
const T0 = 1_756_100_000_000;

let sql: Sql | null = null;
let repository: IrohRepositoryShape | null = null;

function requiredSql(): Sql {
  if (!sql) throw new Error("sql not initialized");
  return sql;
}

beforeAll(async () => {
  if (!runDbTests) return;
  const databaseURL = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
  if (!databaseURL) throw new Error("DATABASE_URL is required when CMUX_DB_TEST=1");
  sql = postgres(databaseURL, { max: 4 });
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
      iroh_relay_preferences,
      account_deletion_tombstones
    restart identity cascade
  `;
});

afterAll(async () => {
  await closeRelayReportClientForTests();
  await closeCloudDbForTests();
  await sql?.end();
});

async function insertBinding(input: {
  readonly userId?: string;
  readonly endpointId?: string;
  readonly revokedAt?: Date;
} = {}): Promise<void> {
  await requiredSql()`
    insert into iroh_endpoint_bindings (
      user_id, device_uuid, app_instance_id, tag, platform, endpoint_id,
      identity_generation, pairing_enabled, revoked_at, revoked_reason
    ) values (
      ${input.userId ?? USER_ID}, ${randomUUID()}, ${randomUUID()}, 'stable',
      'mac', ${input.endpointId ?? ENDPOINT_ID}, 1, true,
      ${input.revokedAt ?? null},
      ${input.revokedAt ? "user_requested" : null}
    )
  `;
}

async function saveCustomRelay(userId: string, url: string): Promise<void> {
  const sql = requiredSql();
  await sql`
    insert into iroh_relay_preferences (account_id, mode, selected_managed_relay_ids, custom_relays)
    values (
      ${userId}, 'custom', '[]'::jsonb,
      ${sql.json([{
        id: "corp1",
        provider: "corp",
        region: "on-prem",
        url,
        authMode: "none",
      }])}
    )
  `;
}

function report(overrides: Partial<RelayAttachReport> = {}): RelayAttachReport {
  return {
    endpointId: ENDPOINT_ID,
    event: "attach",
    relayId: MANAGED_HOSTNAME,
    reportedAt: new Date(T0),
    ...overrides,
  };
}

async function attachState(): Promise<{ url: string | null; reportedAt: Date | null }> {
  const [row] = await requiredSql()<Array<{ url: string | null; reportedAt: Date | null }>>`
    select relay_attached_url as url, relay_attach_reported_at as "reportedAt"
    from iroh_endpoint_bindings
    where endpoint_id = ${ENDPOINT_ID}
  `;
  if (!row) throw new Error("binding row missing");
  return row;
}

describe("relay attach report registry behavior", () => {
  dbTest("publishes a managed relay attachment for an active binding", async () => {
    await insertBinding();
    expect(await applyRelayAttachReport(report())).toBe("applied");
    expect(await attachState()).toEqual({
      url: MANAGED_URL,
      reportedAt: new Date(T0),
    });
  });

  dbTest("a matching detach clears the published route", async () => {
    await insertBinding();
    await applyRelayAttachReport(report());
    expect(await applyRelayAttachReport(report({
      event: "detach",
      reportedAt: new Date(T0 + 1_000),
    }))).toBe("applied");
    expect(await attachState()).toEqual({
      url: null,
      reportedAt: new Date(T0 + 1_000),
    });
  });

  dbTest("drops an out-of-order older attach after a newer detach", async () => {
    await insertBinding();
    await applyRelayAttachReport(report({ reportedAt: new Date(T0) }));
    await applyRelayAttachReport(report({
      event: "detach",
      reportedAt: new Date(T0 + 2_000),
    }));
    expect(await applyRelayAttachReport(report({
      reportedAt: new Date(T0 + 1_000),
    }))).toBe("superseded");
    expect((await attachState()).url).toBeNull();
  });

  dbTest("an attach that ties a detach timestamp wins (make-before-break)", async () => {
    await insertBinding();
    await applyRelayAttachReport(report({
      event: "detach",
      reportedAt: new Date(T0),
    }));
    expect(await applyRelayAttachReport(report({
      reportedAt: new Date(T0),
    }))).toBe("applied");
    expect((await attachState()).url).toBe(MANAGED_URL);
  });

  dbTest("a late detach from an old relay cannot clear a newer attachment", async () => {
    await insertBinding();
    await applyRelayAttachReport(report({
      relayId: OTHER_MANAGED_HOSTNAME,
      reportedAt: new Date(T0),
    }));
    await applyRelayAttachReport(report({ reportedAt: new Date(T0 + 5_000) }));
    expect(await applyRelayAttachReport(report({
      event: "detach",
      relayId: OTHER_MANAGED_HOSTNAME,
      reportedAt: new Date(T0 + 6_000),
    }))).toBe("superseded");
    expect(await attachState()).toEqual({
      url: MANAGED_URL,
      reportedAt: new Date(T0 + 5_000),
    });
  });

  dbTest("ignores reports about unknown endpoints", async () => {
    expect(await applyRelayAttachReport(report())).toBe("unknown_endpoint");
  });

  dbTest("ignores reports about revoked bindings", async () => {
    await insertBinding({ revokedAt: new Date(T0) });
    expect(await applyRelayAttachReport(report())).toBe("unknown_endpoint");
  });

  dbTest("refuses a relay outside the catalog and the account's saved set", async () => {
    await insertBinding();
    expect(await applyRelayAttachReport(report({
      relayId: CUSTOM_HOSTNAME,
    }))).toBe("untrusted_relay");
    expect((await attachState()).url).toBeNull();
  });

  dbTest("publishes the saved custom relay URL verbatim for its hostname", async () => {
    await insertBinding();
    await saveCustomRelay(USER_ID, CUSTOM_URL);
    expect(await applyRelayAttachReport(report({
      relayId: CUSTOM_HOSTNAME,
    }))).toBe("applied");
    expect((await attachState()).url).toBe(CUSTOM_URL);
  });

  dbTest("a custom relay deleted from preferences can still detach cleanly", async () => {
    await insertBinding();
    await saveCustomRelay(USER_ID, CUSTOM_URL);
    await applyRelayAttachReport(report({ relayId: CUSTOM_HOSTNAME }));
    await requiredSql()`delete from iroh_relay_preferences where account_id = ${USER_ID}`;
    expect(await applyRelayAttachReport(report({
      event: "detach",
      relayId: CUSTOM_HOSTNAME,
      reportedAt: new Date(T0 + 1_000),
    }))).toBe("applied");
    expect((await attachState()).url).toBeNull();
  });

  dbTest("a detach for a hostname nothing is attached to is superseded", async () => {
    await insertBinding();
    expect(await applyRelayAttachReport(report({
      event: "detach",
      reportedAt: new Date(T0),
    }))).toBe("superseded");
  });

  dbTest("another account's saved custom relay grants no trust", async () => {
    await insertBinding();
    await saveCustomRelay("user-other", CUSTOM_URL);
    expect(await applyRelayAttachReport(report({
      relayId: CUSTOM_HOSTNAME,
    }))).toBe("untrusted_relay");
  });

  dbTest("revocation clears published attach state", async () => {
    await insertBinding();
    await applyRelayAttachReport(report());
    const [binding] = await requiredSql()<Array<{ id: string }>>`
      select id from iroh_endpoint_bindings where endpoint_id = ${ENDPOINT_ID}
    `;
    if (!repository || !binding) throw new Error("repository not initialized");
    await Effect.runPromise(repository.revokeBinding({
      userId: USER_ID,
      bindingId: binding.id,
      now: new Date(T0 + 1_000),
    }));
    const [row] = await requiredSql()<Array<{ url: string | null }>>`
      select relay_attached_url as url from iroh_endpoint_bindings
      where id = ${binding.id}
    `;
    expect(row?.url ?? null).toBeNull();
  });
});

describe("phone discovery serves the attach-derived relay route", () => {
  dbTest("a discover after a simulated attach report carries the relay hint", async () => {
    if (!repository) throw new Error("repository not initialized");
    await insertBinding();
    await applyRelayAttachReport(report());

    const broker = makeIrohTrustBroker(repository, brokerConfig());
    const discovery = await Effect.runPromise(
      broker.discover(USER_ID, new Date(T0 + 10_000)),
    ) as {
      bindings: ReadonlyArray<{ endpoint_id: string; path_hints: IrohPathHint[] }>;
    };

    const mac = discovery.bindings.find((entry) => entry.endpoint_id === ENDPOINT_ID);
    expect(mac).toBeDefined();
    const relayHints = (mac?.path_hints ?? []).filter((hint) => hint.kind === "relay_url");
    expect(relayHints.map((hint) => hint.value)).toEqual([MANAGED_URL]);
    // The synthesized hint is dialable under the standard client rules.
    expect(relayHints[0]?.source).toBe("native");
    expect(relayHints[0]?.privacy_scope).toBe("public_internet");
    expect(new Date(relayHints[0]?.expires_at ?? 0).getTime())
      .toBeGreaterThan(T0 + 10_000);

    // After a detach report the same fetch no longer advertises the relay.
    await applyRelayAttachReport(report({
      event: "detach",
      reportedAt: new Date(T0 + 20_000),
    }));
    const after = await Effect.runPromise(
      broker.discover(USER_ID, new Date(T0 + 30_000)),
    ) as {
      bindings: ReadonlyArray<{ endpoint_id: string; path_hints: IrohPathHint[] }>;
    };
    const macAfter = after.bindings.find((entry) => entry.endpoint_id === ENDPOINT_ID);
    expect((macAfter?.path_hints ?? []).filter((hint) => hint.kind === "relay_url"))
      .toEqual([]);
  });
});

function brokerConfig(): IrohTrustBrokerConfigShape {
  const grantKeys = generateKeyPairSync("ed25519");
  return {
    lanDiscoverySecretBase64: Buffer.alloc(32, 7).toString("base64"),
    accountSubjectSecretBase64: Buffer.alloc(32, 8).toString("base64"),
    grantSigningPrivateKeyPem: grantKeys.privateKey
      .export({ format: "pem", type: "pkcs8" })
      .toString(),
    grantSigningKid: "current",
    grantVerificationKeysJson: JSON.stringify({
      version: 1,
      current_kid: "current",
      keys: [{
        kid: "current",
        alg: "EdDSA",
        spki_der_base64: grantKeys.publicKey
          .export({ format: "der", type: "spki" })
          .toString("base64"),
      }],
    }),
  };
}
