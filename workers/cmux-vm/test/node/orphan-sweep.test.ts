/**
 * cmux#35013: before cmux#35012 every production create made a VM at the provider and then failed its receipt check,
 * so no ownership row recorded the VM and it ran unpaused. The sweep deletes exactly those: ours, old enough that no
 * create can still record them, and with no row of any state.
 */
import { Effect, Redacted } from "effect";
import { expect, it } from "vitest";
import { ORPHAN_MIN_AGE_MS, orphanSlug, sweepOrphanTunnels, sweepOrphanVms } from "../../src/upstream/orphan-sweep.ts";

const NOW = Date.parse("2026-11-04T12:00:00Z");
const old = new Date(NOW - ORPHAN_MIN_AGE_MS - 60_000).toISOString();
const young = new Date(NOW - ORPHAN_MIN_AGE_MS + 60_000).toISOString();
const id = (n: number) => `vm_${String(n).padStart(26, "0")}`;

interface Listed { id: string; slug: string | null; createdAt: string; metadata: Record<string, string> }
const ours = (n: number, createdAt = old, environment = "production"): Listed => ({
  id: `up-${n}`, slug: orphanSlug(environment, id(n)), createdAt,
  metadata: { cmux_id: id(n), cmux_env: environment, cmux_tenant: "team_alpha" },
});

const provider = (vms: Listed[]) => {
  const live = new Map(vms.map((vm) => [vm.id, vm]));
  const deletes: string[] = [];
  const queries: string[] = [];
  const fetch = async (request: Request) => {
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/v5/vms") {
      queries.push(url.searchParams.get("metadata") ?? "");
      const offset = Number(url.searchParams.get("offset") ?? 0), limit = Number(url.searchParams.get("limit") ?? 50);
      // The provider's metadata filter is ignored here on purpose: the sweep must not trust it.
      const page = [...live.values()].slice(offset, offset + limit).map((vm) => ({ ...vm, state: "running", resources: { cpu: 2, memory: 4096, storage: 8192 }, updatedAt: vm.createdAt }));
      return Response.json({ vms: page, totalCount: live.size, runningCount: live.size, startingCount: 0, pausedCount: 0, stoppedCount: 0 });
    }
    const match = /^\/v5\/vms\/([^/]+)$/.exec(url.pathname);
    if (request.method === "DELETE" && match) {
      const upstreamId = decodeURIComponent(match[1]!);
      deletes.push(upstreamId);
      return live.delete(upstreamId) ? Response.json({}) : Response.json({ code: "NOT_FOUND" }, { status: 404 });
    }
    return new Response(null, { status: 500 });
  };
  return { live, deletes, queries, config: { baseUrl: "https://provider.test", apiKey: Redacted.make("key"), environment: "production" as const, fetch } };
};

const recordedOf = (ids: ReadonlyArray<string>) => (asked: ReadonlyArray<string>) => {
  const found: ReadonlySet<string> = new Set(asked.filter((x) => ids.includes(x)));
  return Effect.succeed(found);
};

it("deletes only old VMs of this environment with our exact slug and no ownership row", async () => {
  const p = provider([
    ours(1), // orphan
    ours(2), // recorded
    ours(3, young), // too young: a create may still record it
    ours(4, old, "staging"), // another environment
    { ...ours(5), slug: "someone-else" }, // not our slug
    { ...ours(6), metadata: { cmux_env: "production", cmux_id: "not-an-id" } },
    { id: "up-7", slug: "unrelated", createdAt: old, metadata: {} },
  ]);
  const report = await Effect.runPromise(sweepOrphanVms(p.config, { nowMs: NOW, dryRun: false, recorded: recordedOf([id(2)]) }));
  expect(report.orphans.map((vm) => vm.upstreamId)).toEqual(["up-1"]);
  expect(report.orphans[0]).toMatchObject({ cmuxId: id(1), tenant: "team_alpha" });
  expect(report.deleted).toEqual(["up-1"]);
  expect(p.deletes).toEqual(["up-1"]);
  expect([...p.live.keys()].sort()).toEqual(["up-2", "up-3", "up-4", "up-5", "up-6", "up-7"]);
  expect(report).toMatchObject({ complete: true, failed: [] });
  expect(p.queries).toEqual(["cmux_env:production"]);
});

it("a dry run lists the same orphans and deletes nothing", async () => {
  const p = provider([ours(1), ours(2)]);
  const report = await Effect.runPromise(sweepOrphanVms(p.config, { nowMs: NOW, dryRun: true, recorded: recordedOf([]) }));
  expect(report.orphans.map((vm) => vm.upstreamId)).toEqual(["up-1", "up-2"]);
  expect(report.deleted).toEqual([]);
  expect(p.deletes).toEqual([]);
});

it("never sweeps younger than the floor, lists every page before deleting, and honours the delete cap", async () => {
  const p = provider(Array.from({ length: 120 }, (_, n) => ours(n + 1)));
  const tooYoung = await Effect.runPromise(sweepOrphanVms(p.config, { nowMs: NOW - 2 * 60_000, minAgeMs: 1, dryRun: true, recorded: recordedOf([]) }));
  expect(tooYoung.orphans).toHaveLength(0);
  const report = await Effect.runPromise(sweepOrphanVms(p.config, { nowMs: NOW, dryRun: false, maxDeletes: 100, recorded: recordedOf([]) }));
  expect(report.listed).toBe(120);
  expect(report.orphans).toHaveLength(120);
  expect(report.deleted).toHaveLength(100);
  expect(p.live.size).toBe(20);
});

it("fails without deleting anything when the ownership lookup fails", async () => {
  const p = provider([ours(1)]);
  const outcome = await Effect.runPromise(Effect.either(sweepOrphanVms(p.config, { nowMs: NOW, dryRun: false, recorded: () => Effect.fail("db down") })));
  expect(outcome._tag).toBe("Left");
  expect(p.deletes).toEqual([]);
});

it("skips a VM a retried create recorded between the listing and its delete", async () => {
  const p = provider([ours(1), ours(2)]);
  let calls = 0;
  // The batch lookup sees no rows; by the time of the per-VM recheck, VM 1 has been recorded.
  const recorded = (asked: ReadonlyArray<string>) => {
    calls += 1;
    const found: ReadonlySet<string> = new Set(calls > 1 ? asked.filter((x) => x === id(1)) : []);
    return Effect.succeed(found);
  };
  const report = await Effect.runPromise(sweepOrphanVms(p.config, { nowMs: NOW, dryRun: false, recorded }));
  expect(report.deleted).toEqual(["up-2"]);
  expect(p.deletes).toEqual(["up-2"]);
});

const device = (n: number) => `dev_${String(n).padStart(26, "0")}`;
const tunnelProvider = (tunnels: ReadonlyArray<{ id: string; slug: string | null; displayName: string | null; attachments?: ReadonlyArray<{ vpcId: string | null }> }>) => {
  const live = new Map(tunnels.map((tunnel) => [tunnel.id, tunnel]));
  const deletes: string[] = [];
  const fetch = async (request: Request) => {
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/v5/tunnels") return Response.json({ tunnels: [...live.values()], totalCount: live.size });
    const match = /^\/v5\/tunnels\/([^/]+)$/.exec(url.pathname);
    if (request.method === "DELETE" && match) {
      const upstreamId = decodeURIComponent(match[1]!);
      deletes.push(upstreamId);
      return live.delete(upstreamId) ? Response.json({}) : Response.json({ code: "NOT_FOUND" }, { status: 404 });
    }
    return new Response(null, { status: 500 });
  };
  return { live, deletes, config: { baseUrl: "https://provider.test", apiKey: Redacted.make("key"), environment: "production" as const, fetch } };
};
const deviceTunnel = (n: number, environment = "production", tenant = "team_alpha", attachments: ReadonlyArray<{ vpcId: string | null }> = [{ vpcId: "vpc-mesh" }]) => ({
  id: `tun-${n}`, slug: `cmux-tun-${environment}-${device(n).replace("_", "-")}`, displayName: `cmux-vm-${environment} ${tenant} ${device(n)}`, attachments,
});
/** A lookup naming `devices`, each on the mesh network "vpc-mesh". */
const naming = (devices: ReadonlyArray<string>) => (owners: ReadonlyArray<{ readonly deviceId: string }>) => {
  const found: ReadonlyMap<string, string> = new Map(owners.filter((owner) => devices.includes(owner.deviceId)).map((owner) => [owner.deviceId, "vpc-mesh"] as const));
  return Effect.succeed(found);
};

it("deletes only this environment's device tunnels, named exactly as their create named them, that the lookup names", async () => {
  const p = tunnelProvider([
    deviceTunnel(1), // sweepable
    deviceTunnel(2), // the lookup keeps it (a live device, or an open attempt)
    deviceTunnel(3, "staging"), // another environment
    { ...deviceTunnel(4), displayName: "someone else's" }, // not the create's name
    { id: "tun-5", slug: "cmux-tun-production-vm-00000000000000000000000005", displayName: null }, // not a device id
    { id: "tun-6", slug: null, displayName: null },
  ]);
  const asked: string[] = [];
  const report = await Effect.runPromise(sweepOrphanTunnels(p.config, {
    dryRun: false,
    sweepable: (owners) => {
      asked.push(...owners.map((owner) => `${owner.tenantId} ${owner.deviceId}`));
      return naming([device(1)])(owners);
    },
  }));
  expect([...new Set(asked)].sort()).toEqual([`team_alpha ${device(1)}`, `team_alpha ${device(2)}`]);
  expect(report.deleted).toEqual(["tun-1"]);
  expect(p.deletes).toEqual(["tun-1"]);
  expect([...p.live.keys()].sort()).toEqual(["tun-2", "tun-3", "tun-4", "tun-5", "tun-6"]);
});

it("skips and reports a named tunnel that is not attached to exactly its mesh's network, and deletes the one that is", async () => {
  const p = tunnelProvider([
    deviceTunnel(1), // on its mesh's network only: deleted
    deviceTunnel(2, "production", "team_alpha", []), // no attachments
    deviceTunnel(3, "production", "team_alpha", [{ vpcId: "vpc-mesh" }, { vpcId: "vpc-other" }]), // its mesh's plus another
    deviceTunnel(4, "production", "team_alpha", [{ vpcId: "vpc-other" }]), // only another
    deviceTunnel(5, "production", "team_alpha", [{ vpcId: null }]), // an attachment with no network id
  ]);
  const report = await Effect.runPromise(sweepOrphanTunnels(p.config, { dryRun: false, sweepable: naming([1, 2, 3, 4, 5].map(device)) }));
  expect(report.deleted).toEqual(["tun-1"]);
  expect([...report.skipped].sort()).toEqual(["tun-2", "tun-3", "tun-4", "tun-5"]);
  expect(p.deletes).toEqual(["tun-1"]);
  expect([...p.live.keys()].sort()).toEqual(["tun-2", "tun-3", "tun-4", "tun-5"]);
});

it("deletes no tunnel when the sweep's lookup fails", async () => {
  const p = tunnelProvider([deviceTunnel(1)]);
  const outcome = await Effect.runPromise(Effect.either(sweepOrphanTunnels(p.config, { dryRun: false, sweepable: () => Effect.fail("db down") })));
  expect(outcome._tag).toBe("Left");
  expect(p.deletes).toEqual([]);
});

it("reads a tunnel listing far over the 1 MiB reply cap as it streams, and still sweeps it", async () => {
  // 4,000 tunnels with a full WireGuard config each: about 3 MiB, streamed in 16 KiB chunks.
  const listing = Array.from({ length: 4_000 }, (_, n) => ({
    ...deviceTunnel(n + 1),
    clientConfig: `[Interface]\nPrivateKey = \nAddress = 100.64.0.1/32\n${"#".repeat(600)}`,
    attachments: [{ vpcId: "vpc-1", address: "10.0.0.2" }],
  }));
  const text = JSON.stringify({ tunnels: listing, totalCount: listing.length });
  expect(text.length).toBeGreaterThan(3 * 1024 * 1024);
  const deletes: string[] = [];
  const fetch = async (request: Request) => {
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/v5/tunnels") {
      const bytes = new TextEncoder().encode(text);
      let offset = 0;
      return new Response(new ReadableStream<Uint8Array>({
        pull(controller) {
          if (offset >= bytes.length) return controller.close();
          controller.enqueue(bytes.slice(offset, offset + 16 * 1024));
          offset += 16 * 1024;
        },
      }), { headers: { "content-type": "application/json" } });
    }
    if (request.method === "DELETE") {
      deletes.push(decodeURIComponent(url.pathname.replace("/v5/tunnels/", "")));
      return Response.json({});
    }
    return new Response(null, { status: 500 });
  };
  const report = await Effect.runPromise(sweepOrphanTunnels(
    { baseUrl: "https://provider.test", apiKey: Redacted.make("key"), environment: "production", fetch },
    { dryRun: false, sweepable: naming([device(3_999)]) },
  ));
  expect(report.listed).toBe(4_000);
  expect(report.deleted).toEqual(["tun-3999"]);
  expect(deletes).toEqual(["tun-3999"]);
});

it("deletes nothing when the listing is cut off", async () => {
  const fetch = async (request: Request) =>
    new URL(request.url).pathname === "/v5/tunnels" && request.method === "GET"
      ? new Response(JSON.stringify({ tunnels: [deviceTunnel(1)] }).slice(0, -3))
      : new Response(null, { status: 500 });
  const outcome = await Effect.runPromise(Effect.either(sweepOrphanTunnels(
    { baseUrl: "https://provider.test", apiKey: Redacted.make("key"), environment: "production", fetch },
    { dryRun: false, sweepable: naming([device(1)]) },
  )));
  expect(outcome._tag).toBe("Left");
});

it("deletes nothing when the listing breaks the JSON grammar after its items", async () => {
  const deletes: string[] = [];
  for (const tail of ["]]}", "]} x", "}}", '],"totalCount":}', '],"tunnels":null}', '],"\\u0074unnels":[]}']) {
    const text = `{"tunnels":[${JSON.stringify(deviceTunnel(1))}${tail}`;
    const fetch = async (request: Request) => {
      const url = new URL(request.url);
      if (url.pathname === "/v5/tunnels" && request.method === "GET") return new Response(text);
      if (request.method === "DELETE") deletes.push(url.pathname);
      return Response.json({});
    };
    const outcome = await Effect.runPromise(Effect.either(sweepOrphanTunnels(
      { baseUrl: "https://provider.test", apiKey: Redacted.make("key"), environment: "production", fetch },
      { dryRun: false, sweepable: naming([device(1)]) },
    )));
    expect(outcome._tag).toBe("Left");
  }
  expect(deletes).toEqual([]);
});
