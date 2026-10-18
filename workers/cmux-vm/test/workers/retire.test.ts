import { afterEach, expect, it } from "vitest";
import { bearer } from "../support/endpoints.ts";
import { makeHarness } from "../support/harness.ts";

type Harness = Awaited<ReturnType<typeof makeHarness>>;
let current: Harness | undefined;
const harness = async () => { current = await makeHarness(); return current; };
afterEach(async () => { await current?.dispose(); current = undefined; });
const retire = (t: Harness, key: string, id: string) => t.request(`/v1/vms/${id}/retire`, bearer(key), { method: "POST" });

it("retires the exact owned VM with a confirmed fence, public receipt and audit", async () => {
  const t = await harness(), owned = t.addVm("team_alpha");
  const key = await t.addKey("team_alpha", ["vm:write"]);
  const r = await retire(t, key, owned.vmId), text = await r.text();
  expect(r.status).toBe(200);
  expect(JSON.parse(text)).toEqual({ id: owned.vmId, state: "paused", retired: true });
  expect(text).not.toContain(owned.upstreamId);
  expect(t.upstream.callsTo("PATCH", /./).map((c) => [c.path, c.json])).toEqual([[`/v5/vms/${owned.upstreamId}`, { maxRunTotalSeconds: 0 }]]);
  expect(t.upstream.callsTo("POST", /exec-await$/)[0]?.json).toEqual({ command: "sync", timeoutMs: 15000, linuxUser: "root" });
  expect(t.audit).toContainEqual(expect.objectContaining({ action: "vm.retire", cmuxId: owned.vmId, outcome: "ok" }));
  expect(t.upstream.callsTo("DELETE", /./)).toHaveLength(0);
});

it.each(["paused", "stopped"])("retires a %s VM without waking it", async (state) => {
  const t = await harness(), owned = t.addVm("team_alpha", state);
  const key = await t.addKey("team_alpha", ["vm:write"]);
  expect((await retire(t, key, owned.vmId)).status).toBe(200);
  expect(t.upstream.callsTo("POST", /./)).toHaveLength(0);
  expect(t.upstream.vms.get(owned.upstreamId)?.state).toBe(state);
});

it("retries an already retired VM without resetting its fence or executing sync", async () => {
  const t = await harness(), owned = t.addVm("team_alpha");
  const key = await t.addKey("team_alpha", ["vm:write"]);
  expect((await retire(t, key, owned.vmId)).status).toBe(200);
  const count = t.upstreamRequests.length;
  expect((await retire(t, key, owned.vmId)).status).toBe(200);
  expect(t.upstreamRequests.slice(count).map((c) => c.method)).toEqual(["GET"]);
});

it("checks permission, tenant and resource allowlist before provider access", async () => {
  const t = await harness(), owned = t.addVm("team_alpha");
  for (const [key, status] of [
    [await t.addKey("team_alpha", ["vm:read"]), 403],
    [await t.addKey("team_bravo", ["vm:write"]), 404],
    [await t.addKey("team_alpha", ["vm:write"], { allowlist: [] }), 404],
  ] as const) expect((await retire(t, key, owned.vmId)).status).toBe(status);
  expect(t.upstreamRequests).toHaveLength(0);
});

it("keeps service label restrictions at the owner", async () => {
  const t = await harness(), owned = t.addVm("team_alpha", "running", { role: "other" });
  const key = await t.addServiceKey({ scopes: ["vm:write"], labels: { role: "team-vm" } });
  const r = await t.request(`/v1/vms/${owned.vmId}/retire`, { ...bearer(key), "X-Cmux-Team-Id": "team_alpha" }, { method: "POST" });
  expect(r.status).toBe(404);
  expect(t.upstreamRequests).toHaveLength(0);
});

it("allows retiring existing resources after the plan lapses", async () => {
  const t = await harness(), owned = t.addVm("team_alpha");
  const key = await t.addKey("team_alpha", ["vm:write"]);
  t.setBilling("team_alpha", false);
  expect((await retire(t, key, owned.vmId)).status).toBe(200);
});

it("confirms a fence whose update answer was lost", async () => {
  const t = await harness(), owned = t.addVm("team_alpha");
  const key = await t.addKey("team_alpha", ["vm:write"]);
  t.upstream.updateReplies.set(owned.upstreamId, () => {
    const vm = t.upstream.vms.get(owned.upstreamId)!;
    vm.maxRunTotalSeconds = 0; vm.state = "paused";
    return Response.json({ message: "private provider detail" }, { status: 503 });
  });
  expect((await retire(t, key, owned.vmId)).status).toBe(200);
});

it("refuses an unconfirmed update without returning private provider errors", async () => {
  const t = await harness(), owned = t.addVm("team_alpha");
  const key = await t.addKey("team_alpha", ["vm:write"]);
  t.upstream.fail("update", 503, 1, { message: "private provider detail" });
  const r = await retire(t, key, owned.vmId);
  expect(r.status).toBe(503);
  expect(await r.text()).not.toContain("private provider detail");
  expect(t.audit).toContainEqual(expect.objectContaining({ action: "vm.retire", outcome: "ServiceUnavailable" }));
});

it("does not treat pause alone as retirement when an update silently does nothing", async () => {
  const t = await harness(), owned = t.addVm("team_alpha", "paused");
  const key = await t.addKey("team_alpha", ["vm:write"]);
  t.upstream.updateReplies.set(owned.upstreamId, () => Response.json({}));
  expect((await retire(t, key, owned.vmId)).status).toBe(503);
});

it("keeps a failed pause fenced, reports no success and permits recovery", async () => {
  const t = await harness(), owned = t.addVm("team_alpha");
  const key = await t.addKey("team_alpha", ["vm:write"]);
  t.upstream.updateReplies.set(owned.upstreamId, () => {
    t.upstream.vms.get(owned.upstreamId)!.maxRunTotalSeconds = 0;
    return Response.json({});
  });
  t.upstream.fail("pause", 503);
  expect((await retire(t, key, owned.vmId)).status).toBe(503);
  expect(t.upstream.vms.get(owned.upstreamId)?.maxRunTotalSeconds).toBe(0);
  expect((await retire(t, key, owned.vmId)).status).toBe(200);
});

it("does not let a failed best-effort disk flush hold back the fence", async () => {
  const t = await harness(), owned = t.addVm("team_alpha");
  const key = await t.addKey("team_alpha", ["vm:write"]);
  t.upstream.fail("exec", 503);
  expect((await retire(t, key, owned.vmId)).status).toBe(200);
});

it("leaves retired files readable and deletable while starts, resume and exec are refused", async () => {
  const t = await harness(), owned = t.addVm("team_alpha");
  const key = await t.addKey("team_alpha", ["vm:write", "vm:read", "vm:files", "vm:exec"]);
  t.upstream.files.set(`${owned.upstreamId}\u0000/saved`, new TextEncoder().encode("saved data"));
  expect((await retire(t, key, owned.vmId)).status).toBe(200);
  for (const action of ["start", "resume", "exec"]) {
    const r = await t.request(`/v1/vms/${owned.vmId}/${action}`, bearer(key), { method: "POST", ...(action === "exec" ? { body: { command: "id" } } : {}) });
    expect(r.status).toBe(409);
  }
  const file = await t.request(`/v1/vms/${owned.vmId}/files/content?path=%2Fsaved`, bearer(key));
  expect(file.status).toBe(200);
  expect(await file.text()).toBe("saved data");
  expect(t.upstream.vms.get(owned.upstreamId)?.state).toBe("paused");
  expect((await t.request(`/v1/vms/${owned.vmId}`, bearer(key), { method: "DELETE" })).status).toBe(204);
});
