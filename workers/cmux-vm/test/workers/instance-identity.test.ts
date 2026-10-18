import { afterEach, expect, it } from "vitest";
import { bearer } from "../support/endpoints.ts";
import { makeHarness } from "../support/harness.ts";

type Harness = Awaited<ReturnType<typeof makeHarness>>;
let current: Harness | undefined;
const harness = async () => { current = await makeHarness(); return current; };
afterEach(async () => { await current?.dispose(); current = undefined; });
const identity = (t: Harness, key: string, id: string) => t.request(`/v1/vms/${id}/identity`, bearer(key));
const fingerprint = async (id: string) => Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`cmux-vm-instance-v1\n${id}`))), (b) => b.toString(16).padStart(2, "0")).join("");

it("returns a canonical instance fingerprint without provider identifiers or network calls", async () => {
  const t = await harness(), owned = t.addVm("team_alpha");
  const key = await t.addKey("team_alpha", ["vm:read"]);
  const r = await identity(t, key, owned.vmId), text = await r.text();
  expect(r.status).toBe(200);
  expect(JSON.parse(text)).toEqual({ id: owned.vmId, scheme: "sha256-v1", fingerprint: await fingerprint(owned.upstreamId) });
  expect(text).not.toContain(owned.upstreamId);
  expect(t.upstreamRequests).toHaveLength(0);
  expect(t.audit).toEqual([]);
});

it("keeps the fingerprint through power changes and distinguishes another allocation", async () => {
  const t = await harness(), a = t.addVm("team_alpha"), b = t.addVm("team_alpha");
  const key = await t.addKey("team_alpha", ["vm:read"]);
  const first = await (await identity(t, key, a.vmId)).json();
  t.upstream.vms.get(a.upstreamId)!.state = "paused";
  expect(await (await identity(t, key, a.vmId)).json()).toEqual(first);
  expect(await (await identity(t, key, b.vmId)).json()).not.toEqual(first);
  expect(t.upstreamRequests).toHaveLength(0);
});

it("applies read scope, tenant and resource allowlist checks before identity disclosure", async () => {
  const t = await harness(), owned = t.addVm("team_alpha");
  for (const [key, status] of [
    [await t.addKey("team_alpha", ["vm:exec"]), 403],
    [await t.addKey("team_bravo", ["vm:read"]), 404],
    [await t.addKey("team_alpha", ["vm:read"], { allowlist: [] }), 404],
  ] as const) expect((await identity(t, key, owned.vmId)).status).toBe(status);
  expect(t.upstreamRequests).toHaveLength(0);
});

it("keeps service label restrictions and refuses malformed or deleted records", async () => {
  const t = await harness(), owned = t.addVm("team_alpha", "running", { role: "other" });
  const service = await t.addServiceKey({ scopes: ["vm:read"], labels: { role: "team-vm" } });
  expect((await t.request(`/v1/vms/${owned.vmId}/identity`, { ...bearer(service), "X-Cmux-Team-Id": "team_alpha" })).status).toBe(404);
  const key = await t.addKey("team_alpha", ["vm:read", "vm:write"]);
  expect((await identity(t, key, "private-provider-reference")).status).toBe(404);
  expect((await t.request(`/v1/vms/${owned.vmId}`, bearer(key), { method: "DELETE" })).status).toBe(204);
  expect((await identity(t, key, owned.vmId)).status).toBe(404);
});

it("does not mistake an allocation receipt for a liveness or access grant", async () => {
  const t = await harness(), owned = t.addVm("team_alpha");
  const key = await t.addKey("team_alpha", ["vm:read"]);
  t.upstream.vms.delete(owned.upstreamId);
  expect((await identity(t, key, owned.vmId)).status).toBe(200);
  expect(t.upstreamRequests).toHaveLength(0);
});
