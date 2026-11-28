/**
 * Whole-tree search of a VM's disk in one request (cmuxterm-hq RFD 0144 piece 2): a paused VM's search is answered
 * from the replica seeded at pause, with no provider file reads and no wake; a running VM, or a paused one whose
 * replica is from another pause, reads the disk.
 */
import { env } from "cloudflare:workers";
import { Effect } from "effect";
import { afterEach, expect, it } from "vitest";
import type { ReplicaFile, ReplicaMeta } from "../../src/replica/match.ts";
import { durableObjectReplicaLayer, memoryReplicaLayer, ReplicaStore } from "../../src/replica/store.ts";
import { bearer } from "../support/endpoints.ts";
import { makeHarness, type HarnessOptions } from "../support/harness.ts";

type Harness = Awaited<ReturnType<typeof makeHarness>>;
let current: Harness | undefined;
const harness = async (options: HarnessOptions = {}) => { current = await makeHarness(options); return current; };
afterEach(async () => { await current?.dispose(); current = undefined; });

const TENANT = "team_alpha";
const encoder = new TextEncoder();
const put = (t: Harness, upstreamId: string, path: string, text: string | Uint8Array) =>
  t.upstream.files.set(`${upstreamId}\u0000${path}`, typeof text === "string" ? encoder.encode(text) : text);
const search = (t: Harness, key: string, vmId: string, query: string, path = "/root/app", limit?: number) =>
  t.request(`/v1/vms/${vmId}/files/search?path=${encodeURIComponent(path)}&query=${encodeURIComponent(query)}${limit === undefined ? "" : `&limit=${limit}`}`, bearer(key));
const seed = (t: Harness, key: string, vmId: string, path = "/root/app") =>
  t.request(`/v1/vms/${vmId}/files/replica?path=${encodeURIComponent(path)}`, bearer(key), { method: "POST" });
const fileReads = (t: Harness, from = 0) => t.upstreamRequests.slice(from).filter((c) => /\/fs\/(read|dir)$/u.test(c.path)).length;
const wakes = (t: Harness) => t.upstreamRequests.filter((c) => c.method === "POST" && /\/(start|exec-await)$/u.test(c.path)).length;

const tree = (t: Harness, upstreamId: string) => {
  put(t, upstreamId, "/root/app/README.md", "cmux\nneedle in the readme\n");
  put(t, upstreamId, "/root/app/src/main.rs", "fn main() {\n    let needle = 1;\n}\n");
  put(t, upstreamId, "/root/app/src/empty.txt", "");
  put(t, upstreamId, "/root/app/node_modules/dep/index.js", "needle");
  put(t, upstreamId, "/root/app/.git/HEAD", "needle");
  put(t, upstreamId, "/root/app/logo.png", new Uint8Array([0x89, 0x50, 0, 0x6e, 0x65, 0x65, 0x64, 0x6c, 0x65]));
  put(t, upstreamId, "/root/other/notes.txt", "needle outside the root");
};

const expected = [
  { path: "/root/app/README.md", line: 2, text: "needle in the readme" },
  { path: "/root/app/src/main.rs", line: 2, text: "    let needle = 1;" },
];

it("seeds a paused VM's replica, then answers its searches with no file reads and no wake", async () => {
  const t = await harness(), vm = t.addVm(TENANT, "paused");
  const key = await t.addKey(TENANT, ["vm:files"]);
  tree(t, vm.upstreamId);

  const seeded = await seed(t, key, vm.vmId);
  expect(seeded.status).toBe(200);
  // Skipped folders are not read; the binary file is kept, unsearched.
  expect(await seeded.json()).toMatchObject({ root: "/root/app", complete: true, files: 4, truncated: 0 });

  const before = t.upstreamRequests.length;
  const found = await search(t, key, vm.vmId, "needle");
  expect(found.status).toBe(200);
  expect(await found.json()).toEqual({ source: "replica", complete: true, scanned: 4, matches: expected });
  expect(fileReads(t, before)).toBe(0);

  // A narrower root under the seeded one is answered from the replica too.
  const narrow = await search(t, key, vm.vmId, "needle", "/root/app/src");
  expect(await narrow.json()).toMatchObject({ source: "replica", scanned: 2, matches: [expected[1]] });
  expect(fileReads(t, before)).toBe(0);
  expect(wakes(t)).toBe(0);
  expect(t.upstream.vms.get(vm.upstreamId)?.state).toBe("paused");
});

it("reads a running VM's disk and keeps no replica for it", async () => {
  const replicas = new Map<string, { meta: ReplicaMeta; files: ReadonlyArray<ReplicaFile> }>();
  const t = await harness({ replicas: memoryReplicaLayer(replicas) }), vm = t.addVm(TENANT, "running");
  const key = await t.addKey(TENANT, ["vm:files"]);
  tree(t, vm.upstreamId);

  const found = await search(t, key, vm.vmId, "needle");
  expect(found.status).toBe(200);
  expect(await found.json()).toEqual({ source: "disk", complete: true, scanned: 4, matches: expected });
  expect(replicas.size).toBe(0);
  expect((await seed(t, key, vm.vmId)).status).toBe(409);
});

it("seeds lazily: a paused VM's first search reads the disk, the next is the replica's", async () => {
  const t = await harness(), vm = t.addVm(TENANT, "paused");
  const key = await t.addKey(TENANT, ["vm:files"]);
  tree(t, vm.upstreamId);

  expect(await (await search(t, key, vm.vmId, "needle")).json()).toMatchObject({ source: "disk", matches: expected });
  const before = t.upstreamRequests.length;
  expect(await (await search(t, key, vm.vmId, "needle")).json()).toMatchObject({ source: "replica", matches: expected });
  expect(fileReads(t, before)).toBe(0);
});

it("drops a replica from an earlier pause: a resume and pause reads the disk again", async () => {
  const t = await harness(), vm = t.addVm(TENANT, "paused");
  const key = await t.addKey(TENANT, ["vm:files", "vm:write"]);
  tree(t, vm.upstreamId);
  expect((await seed(t, key, vm.vmId)).status).toBe(200);

  expect((await t.request(`/v1/vms/${vm.vmId}/resume`, bearer(key), { method: "POST" })).status).toBe(200);
  put(t, vm.upstreamId, "/root/app/new.txt", "a new needle");
  expect(await (await search(t, key, vm.vmId, "new needle")).json()).toMatchObject({ source: "disk", matches: [{ path: "/root/app/new.txt" }] });
  expect((await t.request(`/v1/vms/${vm.vmId}/pause`, bearer(key), { method: "POST" })).status).toBe(200);

  expect(await (await search(t, key, vm.vmId, "new needle")).json()).toMatchObject({ source: "disk", matches: [{ path: "/root/app/new.txt" }] });
  expect(await (await search(t, key, vm.vmId, "new needle")).json()).toMatchObject({ source: "replica", matches: [{ path: "/root/app/new.txt" }] });
});

it("reads the disk for a root outside the replica's", async () => {
  const t = await harness(), vm = t.addVm(TENANT, "paused");
  const key = await t.addKey(TENANT, ["vm:files"]);
  tree(t, vm.upstreamId);
  expect((await seed(t, key, vm.vmId, "/root/app/src")).status).toBe(200);
  expect(await (await search(t, key, vm.vmId, "needle", "/root")).json()).toMatchObject({ source: "disk", scanned: 5 });
});

it("stops at the limit and says the answer is not complete", async () => {
  const t = await harness(), vm = t.addVm(TENANT, "paused");
  const key = await t.addKey(TENANT, ["vm:files"]);
  tree(t, vm.upstreamId);
  expect(await (await search(t, key, vm.vmId, "needle", "/root/app", 1)).json()).toMatchObject({ complete: false, matches: [expected[0]] });
});

it("refuses another tenant's VM, a key without vm:files, and an empty query", async () => {
  const t = await harness(), vm = t.addVm(TENANT, "paused");
  const other = await t.addKey("team_bravo", ["vm:files"]);
  const readOnly = await t.addKey(TENANT, ["vm:read"]);
  const key = await t.addKey(TENANT, ["vm:files"]);
  expect((await search(t, other, vm.vmId, "needle")).status).toBe(404);
  expect((await search(t, readOnly, vm.vmId, "needle")).status).toBe(403);
  expect((await seed(t, other, vm.vmId)).status).toBe(404);
  expect((await search(t, key, vm.vmId, "")).status).toBe(400);
  expect(t.upstreamRequests.filter((c) => c.path.includes(vm.upstreamId))).toEqual([]);
});

it("the Durable Object store keeps, searches, replaces and drops a replica", async () => {
  const layer = durableObjectReplicaLayer(env.PAUSED_REPLICAS);
  const run = <A>(f: (store: typeof ReplicaStore.Service) => Effect.Effect<A, unknown>) =>
    Effect.runPromise(Effect.provide(Effect.flatMap(ReplicaStore, f), layer));
  const vmId = `vm_${crypto.randomUUID()}`;
  const meta: ReplicaMeta = { root: "/root/app", marker: "m1", complete: true, files: 3, bytes: 10, truncated: 0, seededAtMs: 1 };
  const files: ReplicaFile[] = [
    { path: "/root/app/b.txt", text: "x\nneedle b" },
    { path: "/root/app/a.txt", text: "needle a\nneedle again" },
    { path: "/root/app/bin", text: null },
    { path: "/root/apple/c.txt", text: "needle beside the root" },
  ];
  expect(await run((s) => s.meta(vmId))).toBeNull();
  await run((s) => s.replace(vmId, meta, files));
  expect(await run((s) => s.meta(vmId))).toEqual(meta);
  expect(await run((s) => s.search(vmId, "/root/app", "needle", 10))).toEqual({
    scanned: 3,
    matches: [
      { path: "/root/app/a.txt", line: 1, text: "needle a" },
      { path: "/root/app/a.txt", line: 2, text: "needle again" },
      { path: "/root/app/b.txt", line: 2, text: "needle b" },
    ],
  });
  expect((await run((s) => s.search(vmId, "/root/app", "needle", 2))).matches).toHaveLength(2);
  await run((s) => s.replace(vmId, { ...meta, marker: "m2" }, [{ path: "/root/app/z.txt", text: "needle z" }]));
  expect(await run((s) => s.search(vmId, "/root/app", "needle", 10))).toEqual({ scanned: 1, matches: [{ path: "/root/app/z.txt", line: 1, text: "needle z" }] });
  await run((s) => s.drop(vmId));
  expect(await run((s) => s.meta(vmId))).toBeNull();
});
