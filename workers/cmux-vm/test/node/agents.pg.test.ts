/**
 * Agent keys and client sessions (migration 0016) on an in-process Postgres
 * (PGlite): the authentication lookup returns an agent key's labels and
 * budget, the reaper's work list holds exactly the expired or revoked agent
 * keys not cleaned yet, and client sessions whose VM was deleted are orphans.
 */
import { PGlite } from "@electric-sql/pglite";
import { Effect, Layer, Option } from "effect";
import { beforeEach, describe, expect, it } from "vitest";
import ownership from "../../migrations/0001_cmux_vm_ownership.sql?raw";
import s2 from "../../migrations/0002_cmux_vm_display_name_audit.sql?raw";
import creationReceipts from "../../migrations/0010_cmux_vm_creation_receipts.sql?raw";
import uncommittedCreations from "../../migrations/0012_cmux_vm_uncommitted_creations.sql?raw";
import agentKeys from "../../migrations/0016_cmux_vm_agent_keys.sql?raw";
import { AgentStore, sqlAgentStoreLayer } from "../../src/db/agents.ts";
import { ApiKeyAdminStore, sqlApiKeyAdminStoreLayer } from "../../src/db/api-keys.ts";
import { SqlClient, StoreError } from "../../src/db/sql.ts";
import { ApiKeyStore, OwnershipStore, sqlStoresLayer } from "../../src/db/stores.ts";
import { newApiKeyId, newClientSessionId, newVmId, TenantId, UpstreamId, type ApiKeyId } from "../../src/lib/ids.ts";

type Stores = AgentStore | ApiKeyAdminStore | ApiKeyStore | OwnershipStore;

let pg: PGlite;
let layer: Layer.Layer<Stores>;
const run = <A, E>(effect: Effect.Effect<A, E, Stores>) => Effect.runPromise(Effect.provide(effect, layer));

const T = TenantId.make("team_alpha");
const OTHER = TenantId.make("team_bravo");
const at = (minute: number) => new Date(Date.UTC(2026, 9, 21, 0, minute));

beforeEach(async () => {
  pg = new PGlite();
  for (const migration of [ownership, s2, creationReceipts, uncommittedCreations, agentKeys]) await pg.exec(migration);
  const sql = Layer.succeed(SqlClient, {
    query: (operation, text, params) =>
      Effect.tryPromise({ try: async () => (await pg.query(text, [...params])).rows, catch: (cause) => new StoreError({ operation, cause }) }),
  });
  layer = Layer.mergeAll(sqlAgentStoreLayer, sqlApiKeyAdminStoreLayer, sqlStoresLayer).pipe(Layer.provide(sql));
});

const issue = (options: { readonly expiresAt: Date; readonly agent?: boolean; readonly tenantId?: TenantId; readonly hash?: string }) =>
  Effect.gen(function* () {
    const id = newApiKeyId();
    yield* (yield* ApiKeyAdminStore).insert({
      id,
      tenantId: options.tenantId ?? T,
      name: "agent",
      keyHash: options.hash ?? crypto.randomUUID().replaceAll("-", "").padEnd(64, "0"),
      scopes: ["vm:read", "vm:write"],
      resourceAllowlist: null,
      createdBy: "key:issuer",
      createdAt: at(0),
      expiresAt: options.expiresAt,
      ...(options.agent === false ? {} : { agent: { labels: { "cmux.agent": id, role: "chief" }, maxVms: 3, maxUsdPerHour: 1.25 } }),
    });
    return id;
  });

describe("agent keys", () => {
  it("authenticates with its labels and budget; an ordinary key has none", async () => {
    const hash = "a".repeat(64);
    const id = await run(issue({ expiresAt: at(60), hash }));
    const found = await run(Effect.flatMap(ApiKeyStore, (store) => store.findActiveByHash(hash, at(1))));
    expect(Option.map(found, (key) => key.agent)).toEqual(Option.some({ labels: { "cmux.agent": id, role: "chief" }, maxVms: 3, maxUsdPerHour: 1.25 }));
    const plainHash = "b".repeat(64);
    await run(issue({ expiresAt: at(60), agent: false, hash: plainHash }));
    const plain = await run(Effect.flatMap(ApiKeyStore, (store) => store.findActiveByHash(plainHash, at(1))));
    expect(Option.map(plain, (key) => key.agent)).toEqual(Option.some(null));
  });

  it("finds and revokes per tenant, never an ordinary key", async () => {
    const id = await run(issue({ expiresAt: at(60) }));
    const plain = await run(issue({ expiresAt: at(60), agent: false }));
    expect((await run(Effect.flatMap(AgentStore, (store) => store.findAgentKey(T, id))))?.createdBy).toBe("key:issuer");
    expect(await run(Effect.flatMap(AgentStore, (store) => store.findAgentKey(OTHER, id)))).toBeNull();
    expect(await run(Effect.flatMap(AgentStore, (store) => store.findAgentKey(T, plain)))).toBeNull();
    expect(await run(Effect.flatMap(AgentStore, (store) => store.revokeAgentKey(OTHER, id, at(2))))).toBe(false);
    expect(await run(Effect.flatMap(AgentStore, (store) => store.revokeAgentKey(T, plain, at(2))))).toBe(false);
    expect(await run(Effect.flatMap(AgentStore, (store) => store.revokeAgentKey(T, id, at(2))))).toBe(true);
    expect((await run(Effect.flatMap(AgentStore, (store) => store.findAgentKey(T, id))))?.revokedAt).toEqual(at(2));
  });

  it("lists expired and revoked agent keys until they are cleaned", async () => {
    const expired = await run(issue({ expiresAt: at(5) }));
    const revoked = await run(issue({ expiresAt: at(60) }));
    const live = await run(issue({ expiresAt: at(60) }));
    await run(issue({ expiresAt: at(5), agent: false }));
    await run(Effect.flatMap(AgentStore, (store) => store.revokeAgentKey(T, revoked, at(3))));
    const due = (now: Date) => run(Effect.flatMap(AgentStore, (store) => store.dueAgentKeys(now, 10))).then((rows) => rows.map((row) => row.id));
    expect(await due(at(10))).toEqual([revoked, expired]);
    await run(Effect.flatMap(AgentStore, (store) => store.markAgentCleaned(T, expired, at(11))));
    expect(await due(at(12))).toEqual([revoked]);
    expect(await due(at(61))).toEqual([revoked, live] satisfies ReadonlyArray<ApiKeyId>);
  });
});

describe("client sessions", () => {
  const session = (vmId: string, identity: string) => ({
    id: newClientSessionId(),
    tenantId: T,
    vmId,
    upstreamIdentityId: UpstreamId.make(identity),
    linuxUser: "ubuntu",
    createdBy: "key:agent",
    createdAt: at(1),
    revokedAt: null,
  });

  it("lists a VM's live sessions, revokes them, and reports orphans of deleted VMs", async () => {
    const vmId = newVmId();
    await run(
      Effect.flatMap(OwnershipStore, (store) =>
        store.record({ tenantId: T, kind: "vm", cmuxId: vmId, upstreamId: UpstreamId.make("vm-up"), createdBy: "key:agent", createdAt: at(0), displayName: null, labels: {} }),
      ),
    );
    const first = session(vmId, "id-1");
    const second = session(vmId, "id-2");
    await run(Effect.flatMap(AgentStore, (store) => Effect.all([store.insertClientSession(first), store.insertClientSession(second)])));
    expect((await run(Effect.flatMap(AgentStore, (store) => store.liveClientSessions(T, vmId)))).map((row) => row.upstreamIdentityId).sort()).toEqual(["id-1", "id-2"]);
    expect(await run(Effect.flatMap(AgentStore, (store) => store.liveClientSessions(OTHER, vmId)))).toEqual([]);
    await run(Effect.flatMap(AgentStore, (store) => store.markClientSessionRevoked(T, first.id, at(2))));
    expect((await run(Effect.flatMap(AgentStore, (store) => store.findClientSession(T, vmId, first.id))))?.revokedAt).toEqual(at(2));
    expect(await run(Effect.flatMap(AgentStore, (store) => store.orphanClientSessions(10)))).toEqual([]);
    await run(Effect.flatMap(OwnershipStore, (store) => store.markDeleted(T, "vm", vmId, at(3))));
    expect((await run(Effect.flatMap(AgentStore, (store) => store.orphanClientSessions(10)))).map((row) => row.id)).toEqual([second.id]);
  });

  it("refuses a malformed Linux user and a reused provider identity", async () => {
    const vmId = newVmId();
    await expect(run(Effect.flatMap(AgentStore, (store) => store.insertClientSession({ ...session(vmId, "id-x"), linuxUser: "Bad User" })))).rejects.toThrow();
    await run(Effect.flatMap(AgentStore, (store) => store.insertClientSession(session(vmId, "id-y"))));
    await expect(run(Effect.flatMap(AgentStore, (store) => store.insertClientSession(session(vmId, "id-y"))))).rejects.toThrow();
  });
});
