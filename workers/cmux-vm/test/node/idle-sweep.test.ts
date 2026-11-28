/**
 * Leo, 2026-11-27 00:45Z: "why do we have so many staging ones?" The idle sweep deletes this environment's VMs that are
 * paused or stopped and have not run for 24 h, in every tenant, and nothing else (src/upstream/idle-sweep.ts).
 */
import { Effect, Redacted } from "effect";
import { expect, it } from "vitest";
import { IDLE_DELETE_MS, sweepIdleVms } from "../../src/upstream/idle-sweep.ts";
import { orphanSlug } from "../../src/upstream/orphan-sweep.ts";

const NOW = Date.parse("2026-11-27T02:00:00Z");
const old = new Date(NOW - IDLE_DELETE_MS - 60_000).toISOString();
const recent = new Date(NOW - IDLE_DELETE_MS + 60_000).toISOString();
const id = (n: number) => `vm_${String(n).padStart(26, "0")}`;

interface Listed {
  id: string;
  slug: string | null;
  state: string;
  createdAt: string;
  updatedAt: string;
  lastNetworkActivity: string | null;
  metadata: Record<string, string>;
}
const ours = (n: number, over: Partial<Listed> = {}, environment = "staging"): Listed => ({
  id: `up-${n}`, slug: orphanSlug(environment, id(n)), state: "paused", createdAt: old, updatedAt: old, lastNetworkActivity: old,
  metadata: { cmux_id: id(n), cmux_env: environment, cmux_tenant: `tenant-${n % 3}` },
  ...over,
});

const provider = (vms: Listed[], environment: "staging" | "production" = "staging") => {
  const live = new Map(vms.map((vm) => [vm.id, vm]));
  const deletes: string[] = [];
  /** A VM's state as the re-read right before a delete answers it (a start since the listing). */
  const reread = new Map<string, Partial<Listed>>();
  const fetch = async (request: Request) => {
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/v5/vms") {
      const offset = Number(url.searchParams.get("offset") ?? 0), limit = Number(url.searchParams.get("limit") ?? 50);
      // The provider's metadata filter is ignored here on purpose: the sweep must not trust it.
      const page = [...live.values()].slice(offset, offset + limit).map((vm) => ({ ...vm, resources: { cpu: 2, memory: 4096, storage: 8192 } }));
      return Response.json({ vms: page });
    }
    const match = /^\/v5\/vms\/([^/]+)$/.exec(url.pathname);
    if (match) {
      const upstreamId = decodeURIComponent(match[1]!);
      const vm = live.get(upstreamId);
      if (request.method === "GET") return vm ? Response.json({ ...vm, ...reread.get(upstreamId) }) : Response.json({ code: "NOT_FOUND" }, { status: 404 });
      if (request.method === "DELETE") {
        deletes.push(upstreamId);
        return live.delete(upstreamId) ? Response.json({}) : Response.json({ code: "NOT_FOUND" }, { status: 404 });
      }
    }
    return new Response(null, { status: 500 });
  };
  return { live, deletes, reread, config: { baseUrl: "https://provider.test", apiKey: Redacted.make("key"), environment, fetch } };
};

it("deletes only our paused or stopped VMs that have not run for 24 h, in every tenant", async () => {
  const p = provider([
    ours(1), // paused a day ago: deleted
    ours(2, { state: "stopped" }), // stopped a day ago: deleted (another tenant)
    ours(3, { state: "running" }), // running for days: never deleted
    ours(4, { updatedAt: recent }), // paused within the day
    ours(5, { lastNetworkActivity: recent }), // reached within the day
    ours(6, { createdAt: recent, updatedAt: recent, lastNetworkActivity: null }), // made within the day
    ours(7, { state: "pausing" }),
    ours(8, {}, "production"), // another environment
    ours(9, { slug: "someone-else" }), // not our slug
    ours(10, { metadata: { cmux_env: "staging", cmux_id: "not-an-id" } }),
    ours(11, { lastNetworkActivity: "garbage" }), // an unreadable time is never old
    { id: "up-12", slug: "unrelated", state: "paused", createdAt: old, updatedAt: old, lastNetworkActivity: old, metadata: {} },
  ]);
  const report = await Effect.runPromise(sweepIdleVms(p.config, { nowMs: NOW, dryRun: false }));
  expect(report.idle.map((vm) => vm.upstreamId)).toEqual(["up-1", "up-2"]);
  expect(report.idle.map((vm) => vm.tenant)).toEqual(["tenant-1", "tenant-2"]);
  expect(report.deleted).toEqual(["up-1", "up-2"]);
  expect(p.deletes).toEqual(["up-1", "up-2"]);
  expect(report).toMatchObject({ complete: true, kept: [], failed: [] });
});

it("a dry run lists the same VMs and deletes nothing", async () => {
  const p = provider([ours(1), ours(2)]);
  const report = await Effect.runPromise(sweepIdleVms(p.config, { nowMs: NOW, dryRun: true }));
  expect(report.idle.map((vm) => vm.upstreamId)).toEqual(["up-1", "up-2"]);
  expect(report.deleted).toEqual([]);
  expect(p.deletes).toEqual([]);
});

it("keeps a VM started since the listing", async () => {
  const p = provider([ours(1), ours(2)]);
  p.reread.set("up-1", { state: "running" });
  p.reread.set("up-2", { updatedAt: new Date(NOW).toISOString() });
  const report = await Effect.runPromise(sweepIdleVms(p.config, { nowMs: NOW, dryRun: false }));
  expect(report.kept).toEqual(["up-1", "up-2"]);
  expect(p.deletes).toEqual([]);
});

it("never sweeps outside staging, whatever the VMs say", async () => {
  const p = provider([ours(1, {}, "production")], "production");
  const report = await Effect.runPromise(sweepIdleVms(p.config, { nowMs: NOW, dryRun: false }));
  expect(report).toMatchObject({ listed: 0, idle: [], deleted: [] });
  expect(p.deletes).toEqual([]);
});

it("lists every page before deleting and honours the delete cap", async () => {
  const p = provider(Array.from({ length: 120 }, (_, n) => ours(n + 1)));
  const report = await Effect.runPromise(sweepIdleVms(p.config, { nowMs: NOW, dryRun: false, maxDeletes: 100 }));
  expect(report.listed).toBe(120);
  expect(report.idle).toHaveLength(120);
  expect(report.deleted).toHaveLength(100);
  expect(p.live.size).toBe(20);
});
