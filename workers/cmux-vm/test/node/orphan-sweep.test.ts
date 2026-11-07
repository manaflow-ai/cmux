/**
 * cmux#35013: before cmux#35012 every production create made a VM at the provider and then failed its receipt check,
 * so no ownership row recorded the VM and it ran unpaused. The sweep deletes exactly those: ours, old enough that no
 * create can still record them, and with no row of any state.
 */
import { Effect, Redacted } from "effect";
import { expect, it } from "vitest";
import { ORPHAN_MIN_AGE_MS, orphanSlug, sweepOrphanVms } from "../../src/upstream/orphan-sweep.ts";

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
