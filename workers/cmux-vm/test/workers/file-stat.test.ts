import { afterEach, expect, it } from "vitest";
import { bearer } from "../support/endpoints.ts";
import { makeHarness } from "../support/harness.ts";

type Harness = Awaited<ReturnType<typeof makeHarness>>;
let current: Harness | undefined;
const harness = async () => { current = await makeHarness(); return current; };
afterEach(async () => { await current?.dispose(); current = undefined; });
const raw = (extra: object = {}) => ({ size: 12, isFile: true, isDirectory: false, isSymlink: false, permissions: "0640", owner: "ubuntu", group: "staff", modified: "2026-10-01T00:00:00Z", ...extra });
const stat = (t: Harness, key: string, id: string, path = "/srv/team/readme") =>
  t.request(`/v1/vms/${id}/files/stat?path=${encodeURIComponent(path)}`, bearer(key));

it("reads metadata from the exact owned VM and exposes only the public fields", async () => {
  const t = await harness(), owned = t.addVm("team_alpha");
  const key = await t.addKey("team_alpha", ["vm:files"]);
  t.upstream.fileStats.set(`${owned.upstreamId}\u0000/srv/team/readme`, raw({ upstreamId: owned.upstreamId, internalPath: "/private/storage" }));
  const r = await stat(t, key, owned.vmId), text = await r.text();
  expect(r.status).toBe(200);
  expect(JSON.parse(text)).toEqual({ kind: "file", size: 12, mode: 0o640, mtime: 1790812800, owner: "ubuntu", group: "staff" });
  expect(text).not.toContain(owned.upstreamId);
  expect(text).not.toContain("/private/storage");
  expect(t.upstreamRequests.map((c) => [c.method, c.path, c.search.get("path")])).toEqual([["GET", `/v5/vms/${owned.upstreamId}/fs/stat`, "/srv/team/readme"]]);
  expect(t.audit).toEqual([]);
});

it.each(["paused", "stopped"])("reads a %s disk without starting or executing its guest", async (state) => {
  const t = await harness(), owned = t.addVm("team_alpha", state);
  const key = await t.addKey("team_alpha", ["vm:files"]);
  t.upstream.fileStats.set(`${owned.upstreamId}\u0000/srv/team/readme`, raw({ modified: "" }));
  const r = await stat(t, key, owned.vmId);
  expect(r.status).toBe(200);
  expect(await r.json()).toMatchObject({ mtime: null });
  expect(t.upstream.vms.get(owned.upstreamId)?.state).toBe(state);
  expect(t.upstreamRequests.map((c) => c.method)).toEqual(["GET"]);
});

it("reads metadata after a confirmed retirement without lifting its fence", async () => {
  const t = await harness(), owned = t.addVm("team_alpha");
  const key = await t.addKey("team_alpha", ["vm:write", "vm:files"]);
  t.upstream.fileStats.set(`${owned.upstreamId}\u0000/srv/team/readme`, raw());
  expect((await t.request(`/v1/vms/${owned.vmId}/retire`, bearer(key), { method: "POST" })).status).toBe(200);
  const before = t.upstreamRequests.length;
  expect((await stat(t, key, owned.vmId)).status).toBe(200);
  expect(t.upstreamRequests.slice(before).map((c) => c.method)).toEqual(["GET"]);
  expect(t.upstream.vms.get(owned.upstreamId)).toMatchObject({ state: "paused", maxRunTotalSeconds: 0 });
});

it("reports a symlink as a symlink even when the provider also names its target type", async () => {
  const t = await harness(), owned = t.addVm("team_alpha", "paused");
  const key = await t.addKey("team_alpha", ["vm:files"]);
  t.upstream.fileStats.set(`${owned.upstreamId}\u0000/srv/team/readme`, raw({ isSymlink: true, permissions: "120777" }));
  const r = await stat(t, key, owned.vmId);
  expect(r.status).toBe(200);
  expect(await r.json()).toMatchObject({ kind: "symlink", mode: 0o777 });
});

it.each([
  [{ isFile: false, isDirectory: true, permissions: "040755" }, "directory", 0o755],
  [{ isFile: false, isDirectory: false, permissions: "060600" }, "other", 0o600],
] as const)("retains type and permission bits for non-regular entries %#", async (extra, kind, mode) => {
  const t = await harness(), owned = t.addVm("team_alpha");
  const key = await t.addKey("team_alpha", ["vm:files"]);
  t.upstream.fileStats.set(`${owned.upstreamId}\u0000/srv/team/readme`, raw(extra));
  const r = await stat(t, key, owned.vmId);
  expect(r.status).toBe(200);
  expect(await r.json()).toMatchObject({ kind, mode });
});

it("accepts numeric epoch metadata without guessing an unavailable timestamp", async () => {
  const t = await harness(), owned = t.addVm("team_alpha");
  const key = await t.addKey("team_alpha", ["vm:files"]);
  t.upstream.fileStats.set(`${owned.upstreamId}\u0000/srv/team/readme`, raw({ modified: "1790812800" }));
  expect(await (await stat(t, key, owned.vmId)).json()).toMatchObject({ mtime: 1790812800 });
});

it.each([
  ["2026-10-01T02:00:00+02:00", 1790812800],
  ["2026-10-01T00:00:00.999Z", 1790812800],
  ["-1", -1],
] as const)("normalizes a valid modification timestamp %s", async (modified, mtime) => {
  const t = await harness(), owned = t.addVm("team_alpha");
  const key = await t.addKey("team_alpha", ["vm:files"]);
  t.upstream.fileStats.set(`${owned.upstreamId}\u0000/srv/team/readme`, raw({ modified, permissions: "104755" }));
  const r = await stat(t, key, owned.vmId);
  expect(r.status).toBe(200);
  expect(await r.json()).toMatchObject({ mtime, mode: 0o4755 });
});

it("checks scope, current tenant, labels and the resource allowlist before provider access", async () => {
  const t = await harness(), owned = t.addVm("team_alpha", "paused", { role: "other" });
  for (const [key, status] of [
    [await t.addKey("team_alpha", ["vm:read", "vm:exec"]), 403],
    [await t.addKey("team_bravo", ["vm:files"]), 404],
    [await t.addKey("team_alpha", ["vm:files"], { allowlist: [] }), 404],
  ] as const) expect((await stat(t, key, owned.vmId)).status).toBe(status);
  const service = await t.addServiceKey({ scopes: ["vm:files"], labels: { role: "team-vm" } });
  expect((await t.request(`/v1/vms/${owned.vmId}/files/stat?path=%2Fsrv`, { ...bearer(service), "X-Cmux-Team-Id": "team_alpha" })).status).toBe(404);
  expect(t.upstreamRequests).toHaveLength(0);
});

it("rejects unsafe paths before provider access", async () => {
  const t = await harness(), owned = t.addVm("team_alpha");
  const key = await t.addKey("team_alpha", ["vm:files"]);
  for (const path of ["relative", "/srv/../etc", "/a\u0000b", "", `/${"x".repeat(4096)}`]) {
    expect((await stat(t, key, owned.vmId, path)).status).toBe(400);
  }
  expect(t.upstreamRequests).toHaveLength(0);
});

it("returns a stable file-not-found error without exposing provider details", async () => {
  const t = await harness(), owned = t.addVm("team_alpha");
  const key = await t.addKey("team_alpha", ["vm:files"]);
  const r = await stat(t, key, owned.vmId);
  expect(r.status).toBe(404);
  expect(await r.json()).toEqual({ _tag: "NotFound", message: "File not found" });
});

it.each([
  { size: -1 }, { size: Number.MAX_SAFE_INTEGER + 1 }, { permissions: "invalid" },
  { modified: "tomorrow" }, { owner: null }, { isFile: true, isDirectory: true },
  { modified: "2026-02-30T00:00:00Z" }, { modified: "2026-10-01T24:00:00Z" },
  { modified: "999999999999" }, { owner: "x".repeat(257) },
])("refuses malformed metadata instead of inventing archive attributes %#", async (extra) => {
  const t = await harness(), owned = t.addVm("team_alpha");
  const key = await t.addKey("team_alpha", ["vm:files"]);
  t.upstream.fileStats.set(`${owned.upstreamId}\u0000/srv/team/readme`, raw(extra));
  const r = await stat(t, key, owned.vmId);
  expect(r.status).toBe(503);
  expect(await r.text()).not.toContain(owned.upstreamId);
});

it("returns a retryable service error on provider failure without waking the VM", async () => {
  const t = await harness(), owned = t.addVm("team_alpha", "paused");
  const key = await t.addKey("team_alpha", ["vm:files"]);
  t.upstream.fail("stat", 503, 1, { message: "private provider detail" });
  const r = await stat(t, key, owned.vmId);
  expect(r.status).toBe(503);
  expect(await r.text()).not.toContain("private provider detail");
  expect(t.upstreamRequests.map((c) => c.method)).toEqual(["GET"]);
});
