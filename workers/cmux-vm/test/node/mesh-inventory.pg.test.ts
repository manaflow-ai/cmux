import deviceIntents from "../../migrations/0018_cmux_vm_mesh_device_intents.sql?raw";
import deviceIntentsIndex from "../../migrations/0019_cmux_vm_mesh_device_intents_index.sql?raw";
import clientSessionIndex from "../../migrations/0017_cmux_vm_client_session_index.sql?raw";
import agentKeys from "../../migrations/0016_cmux_vm_agent_keys.sql?raw";
import overlayServerCodes from "../../migrations/0015_cmux_vm_overlay_server_codes.sql?raw";
import overlayServers from "../../migrations/0014_cmux_vm_overlay_servers.sql?raw";
import creationReceipts from "../../migrations/0010_cmux_vm_creation_receipts.sql?raw";
import creationReceiptIndex from "../../migrations/0011_cmux_vm_creation_receipt_index.sql?raw";
import overlayPolicy from "../../migrations/0013_cmux_vm_device_overlay_policy.sql?raw";
/**
 * MeshStore.meshInventory against every migration on an in-process Postgres (PGlite): the compile's one read answers
 * exactly what its five reads (listDevices, listOverlayServers, listMembers, deviceAddresses, listRules) answer, in
 * one query, so the batch changes the round trips and nothing a compile sees.
 */
import { PGlite } from "@electric-sql/pglite";
import { Effect, Layer } from "effect";
import { beforeEach, describe, expect, it } from "vitest";
import ownership from "../../migrations/0001_cmux_vm_ownership.sql?raw";
import s2 from "../../migrations/0002_cmux_vm_display_name_audit.sql?raw";
import snapshots from "../../migrations/0003_cmux_vm_snapshot_parent.sql?raw";
import mesh from "../../migrations/0004_cmux_vm_mesh.sql?raw";
import meshM2 from "../../migrations/0005_cmux_vm_mesh_m2.sql?raw";
import meshM3 from "../../migrations/0006_cmux_vm_mesh_m3.sql?raw";
import meshM4 from "../../migrations/0007_cmux_vm_mesh_m4.sql?raw";
import meshM4Retries from "../../migrations/0008_cmux_vm_mesh_m4_retries.sql?raw";
import deviceAddress from "../../migrations/0009_cmux_vm_mesh_device_address.sql?raw";
import uncommittedCreations from "../../migrations/0012_cmux_vm_uncommitted_creations.sql?raw";
import { inventoryOf, MeshStore, sqlMeshStoreLayer } from "../../src/db/mesh.ts";
import { SqlClient, StoreError } from "../../src/db/sql.ts";
import { ApiKeyStore, AuditStore, OwnershipStore, sqlStoresLayer } from "../../src/db/stores.ts";
import { newDeviceId, newMeshId, newTunnelId, newVmId, TenantId, UpstreamId } from "../../src/lib/ids.ts";

const ALL = [ownership, s2, snapshots, mesh, meshM2, meshM3, meshM4, meshM4Retries, deviceAddress, creationReceipts, creationReceiptIndex, uncommittedCreations, overlayPolicy, overlayServers, overlayServerCodes, agentKeys, clientSessionIndex, deviceIntents, deviceIntentsIndex];

const T = TenantId.make("team_alpha");
const OTHER = TenantId.make("team_bravo");
const t0 = Date.UTC(2026, 9, 8, 12, 0);
const at = (ms: number) => new Date(t0 + ms);

let pg: PGlite;
let queries: Array<string>;
let layer: Layer.Layer<MeshStore | OwnershipStore | ApiKeyStore | AuditStore>;
const run = <A, E>(effect: Effect.Effect<A, E, MeshStore | OwnershipStore>) => Effect.runPromise(Effect.provide(effect, layer));

beforeEach(async () => {
  pg = new PGlite();
  for (const migration of ALL) await pg.exec(migration);
  queries = [];
  const sql = Layer.succeed(SqlClient, {
    query: (operation, text, params) =>
      Effect.tryPromise({
        try: async () => {
          queries.push(operation);
          return (await pg.query(text, [...params])).rows;
        },
        catch: (cause) => new StoreError({ operation, cause }),
      }),
  });
  layer = Layer.mergeAll(sqlMeshStoreLayer, sqlStoresLayer).pipe(Layer.provide(sql));
});

/** A P-256 install key as the schema stores it: base64 of a 65-byte uncompressed point (0x04, then 64 bytes). */
const installKey = (n: number) => btoa(String.fromCharCode(4, ...Array.from({ length: 64 }, (_, i) => (n * 31 + i) % 256)));

const device = (meshId: string, n: number) => ({
  deviceId: newDeviceId(),
  meshId,
  tunnelId: newTunnelId(),
  name: `d${n}`,
  wgPublicKey: btoa(`device-public-key-${String(n).padStart(14, "0")}`),
  installPublicKey: n % 2 === 0 ? null : installKey(n),
  createdBy: "user:user_ada",
  // Out of id order, so the created_at ordering is what puts them in order.
  createdAt: at(1_000 - n),
});

/** A mesh with every kind of row the compile reads, and rows of other meshes and tenants it must not. */
const seed = (meshId: string) =>
  Effect.gen(function* () {
    const store = yield* MeshStore;
    const owned = yield* OwnershipStore;
    const devices = [1, 2, 3].map((n) => device(meshId, n));
    for (const row of devices) yield* store.recordDevice(T, row);
    const gone = device(meshId, 4);
    yield* store.recordDevice(T, gone);
    yield* store.markDeviceDeleted(T, gone.deviceId, at(5));
    yield* store.recordDevice(T, device(newMeshId(), 5));
    yield* store.recordDevice(OTHER, device(meshId, 6));
    expect(yield* store.setDeviceAddress(T, devices[0]!.deviceId, "2600:1700:abcd:1::5", at(10))).toBe(true);
    expect(yield* store.setDeviceAddress(T, devices[2]!.deviceId, "2a01:4f8::1", at(11))).toBe(true);
    for (const [n, tenant] of [[7, T], [8, T], [9, OTHER]] as const) {
      expect(yield* store.recordOverlayServer(tenant, {
        deviceId: newDeviceId(),
        meshId,
        name: `s${n}`,
        wgPublicKey: btoa(`server-public-key-${String(n).padStart(14, "0")}`),
        installPublicKey: installKey(n),
        createdBy: "user:user_ada",
        createdAt: at(n),
      })).toBe(true);
    }
    const base = { tenantId: T, createdBy: "key:test", createdAt: at(0), displayName: null, labels: {} };
    const vms = [newVmId(), newVmId(), newVmId()];
    for (const [i, vmId] of vms.entries()) {
      yield* owned.record({ ...base, kind: "vm", cmuxId: vmId, upstreamId: UpstreamId.make(`vm-${i}`) });
      yield* store.attachMember(T, { meshId, vmId, ipv4: i === 1 ? null : `10.128.0.${5 + i}`, attachedAt: at(100 - i) });
    }
    yield* owned.markDeleted(T, "vm", vms[2]!, at(200));
    const [d0, d1] = devices;
    yield* store.recordRule(T, { meshId, key: `${d0!.deviceId}>${vms[0]}:tcp:22`, upstreamRuleId: "fwr-1", deviceId: d0!.deviceId, vmId: vms[0]!, protocol: "tcp", port: 22, createdAt: at(300) });
    yield* store.recordRule(T, { meshId, key: `${d1!.deviceId}>${vms[1]}:icmp:*`, upstreamRuleId: "fwr-2", deviceId: d1!.deviceId, vmId: vms[1]!, protocol: "icmp", port: null, createdAt: at(301) });
    const dropped = `${d0!.deviceId}>${vms[1]}:udp:53`;
    yield* store.recordRule(T, { meshId, key: dropped, upstreamRuleId: "fwr-3", deviceId: d0!.deviceId, vmId: vms[1]!, protocol: "udp", port: 53, createdAt: at(302) });
    yield* store.markRuleDeleted(T, meshId, dropped, at(303));
  });

describe("MeshStore.meshInventory", () => {
  it("answers exactly what the five reads answer, in one query", async () => {
    const meshId = newMeshId();
    await run(seed(meshId));
    const five = await run(Effect.flatMap(MeshStore, (store) => inventoryOf(store)(T, meshId)));
    queries = [];
    const one = await run(Effect.flatMap(MeshStore, (store) => store.meshInventory(T, meshId)));
    expect(queries).toEqual(["mesh.inventory"]);
    expect(one).toEqual(five);
    // The fixture is not trivially empty: every list has rows, in each read's own order, and the rows the reads
    // filter out (a deleted device, a deleted VM's member row, a deleted rule, another mesh or tenant) are out.
    expect([one.devices.length, one.servers.length, one.members.length, one.deviceIpv6.size, one.rules.length]).toEqual([3, 2, 2, 2, 2]);
    expect(one.devices.map((d) => d.name)).toEqual(["d3", "d2", "d1"]);
    expect(one.members.map((m) => m.ipv4)).toEqual([null, "10.128.0.5"]);
    expect(one.devices[0]!.createdAt).toBeInstanceOf(Date);
  });

  it("answers empty lists for a mesh with nothing in it, in one query", async () => {
    queries = [];
    const one = await run(Effect.flatMap(MeshStore, (store) => store.meshInventory(T, newMeshId())));
    expect(queries).toEqual(["mesh.inventory"]);
    expect(one).toEqual({ devices: [], servers: [], members: [], deviceIpv6: new Map(), rules: [] });
  });
});
