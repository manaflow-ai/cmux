/**
 * exists, mkdir, remove and resumable uploads (cx-b4h.2): the exact owned VM,
 * schema path validation before the provider, audit without paths, and upload
 * handles that open only for the VM they were issued for. Scope and
 * cross-tenant isolation run for every route in isolation.test.ts.
 */
import { afterEach, expect, it } from "vitest";
import { bearer } from "../support/endpoints.ts";
import { makeHarness, type HarnessOptions } from "../support/harness.ts";

type Harness = Awaited<ReturnType<typeof makeHarness>>;
let current: Harness | undefined;
const harness = async (options: HarnessOptions = {}) => { current = await makeHarness(options); return current; };
afterEach(async () => { await current?.dispose(); current = undefined; });

const TENANT = "team_alpha";
const q = (path: string) => encodeURIComponent(path);
const bytes = (text: string) => new TextEncoder().encode(text);
const sha256 = async (data: Uint8Array) =>
  Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", data)), (byte) => byte.toString(16).padStart(2, "0")).join("");

const begin = (t: Harness, key: string, vmId: string, body: unknown) =>
  t.request(`/v1/vms/${vmId}/files/uploads`, bearer(key), { method: "POST", body });
const chunk = (t: Harness, key: string, vmId: string, uploadId: string, offset: number, data: Uint8Array) =>
  t.send(`/v1/vms/${vmId}/files/uploads/${uploadId}?offset=${offset}`, bearer(key), "PUT", data);
const uploadIdOf = async (response: Response): Promise<string> => {
  const body: unknown = await response.json();
  const id = typeof body === "object" && body !== null && "uploadId" in body ? body.uploadId : null;
  if (typeof id !== "string") throw new Error("no uploadId");
  return id;
};

it("checks whether a path exists on the exact VM without auditing", async () => {
  const t = await harness(), { vmId, upstreamId } = t.addVm(TENANT, "paused");
  const key = await t.addKey(TENANT, ["vm:files"]);
  t.upstream.files.set(`${upstreamId}\u0000/srv/a.txt`, bytes("a"));
  const yes = await t.request(`/v1/vms/${vmId}/files/exists?path=${q("/srv/a.txt")}`, bearer(key));
  const no = await t.request(`/v1/vms/${vmId}/files/exists?path=${q("/srv/b.txt")}`, bearer(key));
  expect([yes.status, await yes.json()]).toEqual([200, { exists: true }]);
  expect([no.status, await no.json()]).toEqual([200, { exists: false }]);
  expect(t.upstream.callsTo("GET", /\/fs\/exists$/).map((c) => [c.path, c.search.get("path")])).toEqual([
    [`/v5/vms/${upstreamId}/fs/exists`, "/srv/a.txt"],
    [`/v5/vms/${upstreamId}/fs/exists`, "/srv/b.txt"],
  ]);
  expect(t.upstream.vms.get(upstreamId)?.state).toBe("paused");
  expect(t.audit).toEqual([]);
});

it("makes a directory with its parents and removes paths, auditing without the path", async () => {
  const t = await harness(), { vmId, upstreamId } = t.addVm(TENANT);
  const key = await t.addKey(TENANT, ["vm:files"]);
  const made = await t.request(`/v1/vms/${vmId}/files/directories`, bearer(key), { method: "POST", body: { path: "/srv/secret-project/deep" } });
  expect(made.status).toBe(204);
  expect(t.upstream.callsTo("POST", /\/fs\/mkdir$/).map((c) => [c.path, c.json])).toEqual([[`/v5/vms/${upstreamId}/fs/mkdir`, { path: "/srv/secret-project/deep" }]]);

  t.upstream.files.set(`${upstreamId}\u0000/srv/secret-project/deep/x`, bytes("x"));
  const removed = await t.request(`/v1/vms/${vmId}/files?path=${q("/srv/secret-project/deep")}`, bearer(key), { method: "DELETE" });
  expect(removed.status).toBe(204);
  expect(t.upstream.files.has(`${upstreamId}\u0000/srv/secret-project/deep/x`)).toBe(false);
  expect(t.upstream.callsTo("DELETE", /\/fs\/remove$/).map((c) => c.search.get("path"))).toEqual(["/srv/secret-project/deep"]);

  const missing = await t.request(`/v1/vms/${vmId}/files?path=${q("/srv/none")}`, bearer(key), { method: "DELETE" });
  expect(missing.status).toBe(404);
  expect(await missing.json()).toEqual({ _tag: "NotFound", message: "File not found" });

  expect(t.audit.map((row) => [row.action, row.cmuxId, row.outcome])).toEqual([
    ["vm.files.mkdir", vmId, "ok"],
    ["vm.files.remove", vmId, "ok"],
    ["vm.files.remove", vmId, "NotFound"],
  ]);
  expect(JSON.stringify(t.audit)).not.toContain("secret-project");
});

it("refuses mkdir and remove on a retired VM without lifting its fence", async () => {
  const t = await harness(), { vmId, upstreamId } = t.addVm(TENANT);
  const key = await t.addKey(TENANT, ["vm:write", "vm:files"]);
  expect((await t.request(`/v1/vms/${vmId}/retire`, bearer(key), { method: "POST" })).status).toBe(200);
  t.upstream.files.set(`${upstreamId}\u0000/srv/keep`, bytes("k"));
  expect((await t.request(`/v1/vms/${vmId}/files/directories`, bearer(key), { method: "POST", body: { path: "/srv/new" } })).status).toBe(409);
  expect((await t.request(`/v1/vms/${vmId}/files?path=${q("/srv/keep")}`, bearer(key), { method: "DELETE" })).status).toBe(409);
  expect((await begin(t, key, vmId, { path: "/srv/big", size: 1 })).status).toBe(409);
  expect(t.upstream.files.has(`${upstreamId}\u0000/srv/keep`)).toBe(true);
  expect(t.upstream.vms.get(upstreamId)).toMatchObject({ maxRunTotalSeconds: 0 });
});

it("rejects unsafe paths on every new route before provider access", async () => {
  const t = await harness(), { vmId } = t.addVm(TENANT);
  const key = await t.addKey(TENANT, ["vm:files"]);
  for (const path of ["relative", "/srv/../etc", "/a\u0000b", "", `/${"x".repeat(4096)}`]) {
    expect((await t.request(`/v1/vms/${vmId}/files/exists?path=${q(path)}`, bearer(key))).status).toBe(400);
    expect((await t.request(`/v1/vms/${vmId}/files?path=${q(path)}`, bearer(key), { method: "DELETE" })).status).toBe(400);
    expect((await t.request(`/v1/vms/${vmId}/files/directories`, bearer(key), { method: "POST", body: { path } })).status).toBe(400);
    expect((await begin(t, key, vmId, { path, size: 1 })).status).toBe(400);
  }
  expect(t.upstreamRequests).toHaveLength(0);
});

it("uploads a file in resumable chunks and commits it atomically", async () => {
  const t = await harness(), { vmId, upstreamId } = t.addVm(TENANT);
  const key = await t.addKey(TENANT, ["vm:files"]);
  const data = bytes("hello, resumable world");
  const started = await begin(t, key, vmId, { path: "/srv/big.bin", size: data.length, sha256: (await sha256(data)).toUpperCase(), mode: 0o644 });
  expect(started.status).toBe(201);
  const startedText = await started.clone().text();
  const uploadId = await uploadIdOf(started);
  expect(uploadId).toMatch(/^upl_[A-Za-z0-9_-]+$/);
  const providerUpload = [...t.upstream.uploads.values()][0];
  expect(providerUpload).toBeDefined();
  expect(startedText).not.toContain(providerUpload?.id ?? "missing");
  expect(startedText).not.toContain(upstreamId);
  expect(startedText).not.toContain("host-leak-check");
  expect(JSON.parse(startedText)).toMatchObject({ path: "/srv/big.bin", size: data.length, receivedBytes: 0, maxChunkBytes: 96 * 1024 * 1024 });
  expect(t.upstream.callsTo("POST", /\/fs\/uploads$/)[0]?.json).toEqual({ path: "/srv/big.bin", size: data.length, sha256: await sha256(data), mode: 0o644 });

  const first = await chunk(t, key, vmId, uploadId, 0, data.slice(0, 7));
  expect([first.status, await first.json()]).toEqual([200, expect.objectContaining({ uploadId, receivedBytes: 7 })]);
  // A retried chunk at an offset already received is acknowledged, not appended again.
  expect(await (await chunk(t, key, vmId, uploadId, 0, data.slice(0, 7))).json()).toMatchObject({ receivedBytes: 7 });
  expect((await chunk(t, key, vmId, uploadId, 20, data.slice(7))).status).toBe(409);
  expect((await chunk(t, key, vmId, uploadId, 7, data.slice(7))).status).toBe(200);
  const status = await t.request(`/v1/vms/${vmId}/files/uploads/${uploadId}`, bearer(key));
  expect(await status.json()).toMatchObject({ uploadId, receivedBytes: data.length, size: data.length });

  expect((await t.request(`/v1/vms/${vmId}/files/uploads/${uploadId}/commit`, bearer(key), { method: "POST" })).status).toBe(204);
  expect(new TextDecoder().decode(t.upstream.files.get(`${upstreamId}\u0000/srv/big.bin`))).toBe("hello, resumable world");
  expect(t.upstream.callsTo("PUT", /\/fs\/uploads\//).map((c) => c.path)).toEqual(Array.from({ length: 4 }, () => `/v5/vms/${upstreamId}/fs/uploads/${providerUpload?.id}`));
  expect(t.audit.map((row) => [row.action, row.cmuxId, row.outcome])).toEqual([
    ["vm.files.upload.begin", vmId, "ok"],
    ["vm.files.upload.commit", vmId, "ok"],
  ]);
});

it("opens an upload handle only for the VM it was issued for", async () => {
  const t = await harness(), a = t.addVm(TENANT), b = t.addVm(TENANT);
  const key = await t.addKey(TENANT, ["vm:files"]);
  const uploadId = await uploadIdOf(await begin(t, key, a.vmId, { path: "/srv/f", size: 3 }));
  const before = t.upstreamRequests.length;
  const tampered = `${uploadId.slice(0, -2)}${uploadId.endsWith("AA") ? "BB" : "AA"}`;
  for (const [vmId, id] of [[b.vmId, uploadId], [a.vmId, tampered], [a.vmId, "upl_short"], [a.vmId, "not-an-upload"]] as const) {
    for (const response of [
      await t.request(`/v1/vms/${vmId}/files/uploads/${id}`, bearer(key)),
      await chunk(t, key, vmId, id, 0, bytes("abc")),
      await t.request(`/v1/vms/${vmId}/files/uploads/${id}/commit`, bearer(key), { method: "POST" }),
      await t.request(`/v1/vms/${vmId}/files/uploads/${id}`, bearer(key), { method: "DELETE" }),
    ]) {
      expect(response.status).toBe(404);
      expect(await response.json()).toEqual({ _tag: "NotFound", message: "Upload not found" });
    }
  }
  expect(t.upstreamRequests.slice(before).filter((c) => c.path.includes("/fs/uploads/"))).toEqual([]);
  // Another tenant cannot reach the VM at all.
  const other = await t.addKey("team_bravo", ["vm:files"]);
  expect((await t.request(`/v1/vms/${a.vmId}/files/uploads/${uploadId}`, bearer(other))).status).toBe(404);
});

it("applies the tenant's chunk and file limits before the provider", async () => {
  const t = await harness({ maxUploadBytes: 4, maxResumableUploadBytes: 10 }), { vmId } = t.addVm(TENANT);
  const key = await t.addKey(TENANT, ["vm:files"]);
  const tooBig = await begin(t, key, vmId, { path: "/srv/f", size: 11 });
  expect(tooBig.status).toBe(413);
  expect(await tooBig.json()).toMatchObject({ _tag: "PayloadTooLarge", maxBytes: 10 });
  expect(t.upstreamRequests).toHaveLength(0);
  const started = await begin(t, key, vmId, { path: "/srv/f", size: 10 });
  const uploadId = await uploadIdOf(started);
  const before = t.upstreamRequests.length;
  const big = await chunk(t, key, vmId, uploadId, 0, bytes("12345"));
  expect(big.status).toBe(413);
  expect(await big.json()).toMatchObject({ maxBytes: 4 });
  expect(t.upstreamRequests.length).toBe(before);
  expect(await (await chunk(t, key, vmId, uploadId, 0, bytes("1234"))).json()).toMatchObject({ receivedBytes: 4, maxChunkBytes: 4 });
});

it("keeps an upload open after a failed commit, and abandons it on abort", async () => {
  const t = await harness(), { vmId, upstreamId } = t.addVm(TENANT);
  const key = await t.addKey(TENANT, ["vm:files"]);
  const uploadId = await uploadIdOf(await begin(t, key, vmId, { path: "/srv/f", size: 3, sha256: "0".repeat(64) }));
  expect((await t.request(`/v1/vms/${vmId}/files/uploads/${uploadId}/commit`, bearer(key), { method: "POST" })).status).toBe(400);
  await chunk(t, key, vmId, uploadId, 0, bytes("abc"));
  const mismatch = await t.request(`/v1/vms/${vmId}/files/uploads/${uploadId}/commit`, bearer(key), { method: "POST" });
  expect(mismatch.status).toBe(400);
  expect(t.upstream.files.has(`${upstreamId}\u0000/srv/f`)).toBe(false);
  expect((await t.request(`/v1/vms/${vmId}/files/uploads/${uploadId}`, bearer(key))).status).toBe(200);
  expect((await t.request(`/v1/vms/${vmId}/files/uploads/${uploadId}`, bearer(key), { method: "DELETE" })).status).toBe(204);
  expect(t.upstream.uploads.size).toBe(0);
  expect((await t.request(`/v1/vms/${vmId}/files/uploads/${uploadId}`, bearer(key))).status).toBe(404);
  expect(t.audit.map((row) => [row.action, row.outcome])).toEqual([
    ["vm.files.upload.begin", "ok"],
    ["vm.files.upload.commit", "BadRequest"],
    ["vm.files.upload.commit", "BadRequest"],
    ["vm.files.upload.abort", "ok"],
  ]);
});

it("lets a service key use the new routes only on VMs carrying its labels", async () => {
  const t = await harness();
  const mine = t.addVm(TENANT, "running", { role: "chief" }), theirs = t.addVm(TENANT);
  const service = await t.addServiceKey({ scopes: ["vm:files"] });
  const headers = { ...bearer(service), "X-Cmux-Team-Id": TENANT };
  expect((await t.request(`/v1/vms/${mine.vmId}/files/exists?path=%2Fsrv`, headers)).status).toBe(200);
  expect((await t.request(`/v1/vms/${theirs.vmId}/files/exists?path=%2Fsrv`, headers)).status).toBe(404);
  expect((await t.request(`/v1/vms/${theirs.vmId}/files/directories`, headers, { method: "POST", body: { path: "/srv/x" } })).status).toBe(404);
  expect((await t.request(`/v1/vms/${theirs.vmId}/files/uploads`, headers, { method: "POST", body: { path: "/srv/x", size: 1 } })).status).toBe(404);
});
