import { Schema } from "effect";
import { afterEach, expect, it } from "vitest";
import { Mesh } from "../../src/api/mesh.ts";
import { ALL_SCOPES, bearer } from "../support/endpoints.ts";
import { makeHarness } from "../support/harness.ts";
import { enrollBody, makeInstallKey, rotateBody } from "../support/mesh-signing.ts";

// A service key (cx-b4h.13) reaches only rows carrying its required labels. A device it enrolls (cmux-platform enrolls a
// Mac as a provider mesh device this way) records those labels on its device and tunnel rows, so the same key can rotate
// it, read its tunnel and delete it. Before, the rows had no labels: the delete answered 404 and the tunnel stayed up.

const SERVICE = "cloud-platform-dev";
const TEAM = "team_personal_new";
const LABELS = { role: "cloud" };
const Enrolled = Schema.Struct({ device: Schema.Struct({ id: Schema.String }), tunnel: Schema.Struct({ tunnelId: Schema.String }) });
type Harness = Awaited<ReturnType<typeof makeHarness>>;
let h: Harness | undefined;
afterEach(async () => { await h?.dispose(); h = undefined; });

const start = async () => {
  h = await makeHarness({ mesh: { tenants: [], services: [SERVICE] } });
  h.setBilling(TEAM, true);
  return h;
};
const serviceKey = (harness: Harness, labels: Readonly<Record<string, string>> = LABELS) =>
  harness.addServiceKey({ id: SERVICE, scopes: ["mesh:read", "mesh:write", "mesh:join"], labels });
const as = (secret: string, extra: Record<string, string> = {}) => ({ ...bearer(secret), "x-cmux-team-id": TEAM, ...extra });

const serviceMesh = async (harness: Harness, key: string) => {
  const created = await harness.request("/v1/mesh-creations", as(key, { "idempotency-key": "cloud-team-network" }), {
    method: "POST",
    body: { displayName: "Cloud network", labels: LABELS },
  });
  expect(created.status).toBe(201);
  return Schema.decodeUnknownSync(Mesh)(await created.json()).id;
};

const enroll = async (harness: Harness, mesh: string, headers: Record<string, string>) => {
  const install = await makeInstallKey();
  const reply = await harness.request(`/v1/meshes/${mesh}/devices`, headers, {
    method: "POST",
    body: await enrollBody(install, mesh, { name: "provider-mac", wgPublicKey: btoa("a".repeat(32)) }),
  });
  expect(reply.status).toBe(201);
  const body = Schema.decodeUnknownSync(Enrolled)(await reply.json());
  return { install, deviceId: body.device.id, tunnelId: body.tunnel.tunnelId };
};

const tunnelDeletes = (harness: Harness) => harness.upstream.callsTo("DELETE", /^\/v5\/tunnels\/[^/]+$/u).length;

it("lets the service key that enrolled a device rotate it, read its tunnel and delete it", async () => {
  const harness = await start();
  const key = await serviceKey(harness);
  const mesh = await serviceMesh(harness, key);
  const { install, deviceId, tunnelId } = await enroll(harness, mesh, as(key));

  for (const cmuxId of [deviceId, tunnelId]) {
    expect(harness.resources.find((row) => row.cmuxId === cmuxId)).toMatchObject({ createdBy: `service:${SERVICE}`, labels: LABELS });
  }
  expect((await harness.request(`/v1/devices/${deviceId}`, as(key))).status).toBe(200);
  const rotated = await harness.request(`/v1/devices/${deviceId}/rotate-key`, as(key), {
    method: "POST",
    body: await rotateBody(install, deviceId, btoa("b".repeat(32))),
  });
  expect(rotated.status).toBe(200);
  expect((await harness.request(`/v1/tunnels/${tunnelId}`, as(key))).status).toBe(200);

  const before = tunnelDeletes(harness);
  const deleted = await harness.request(`/v1/devices/${deviceId}`, as(key), { method: "DELETE" });
  expect(deleted.status).toBe(204);
  expect(tunnelDeletes(harness)).toBe(before + 1);
  expect((await harness.request(`/v1/devices/${deviceId}`, as(key))).status).toBe(404);
});

it("keeps a device at 404 for the same service with other required labels", async () => {
  const harness = await start();
  const key = await serviceKey(harness);
  const mesh = await serviceMesh(harness, key);
  const { install, deviceId, tunnelId } = await enroll(harness, mesh, as(key));
  // Same service id (so the same creator), different labels: only the labels can refuse it.
  const other = await serviceKey(harness, { role: "other" });

  expect((await harness.request(`/v1/devices/${deviceId}`, as(other))).status).toBe(404);
  expect((await harness.request(`/v1/tunnels/${tunnelId}`, as(other))).status).toBe(404);
  const rotated = await harness.request(`/v1/devices/${deviceId}/rotate-key`, as(other), {
    method: "POST",
    body: await rotateBody(install, deviceId, btoa("b".repeat(32))),
  });
  expect(rotated.status).toBe(404);
  const before = tunnelDeletes(harness);
  expect((await harness.request(`/v1/devices/${deviceId}`, as(other), { method: "DELETE" })).status).toBe(404);
  expect(tunnelDeletes(harness)).toBe(before);
  expect((await harness.request(`/v1/devices/${deviceId}`, as(key))).status).toBe(200);
});

it("records no labels for a tenant key's device, which it still deletes", async () => {
  const harness = await start();
  const key = await serviceKey(harness);
  const mesh = await serviceMesh(harness, key);
  const owner = await harness.addKey(TEAM, ALL_SCOPES);
  const { deviceId, tunnelId } = await enroll(harness, mesh, bearer(owner));

  for (const cmuxId of [deviceId, tunnelId]) expect(harness.resources.find((row) => row.cmuxId === cmuxId)?.labels).toEqual({});
  expect((await harness.request(`/v1/tunnels/${tunnelId}`, bearer(owner))).status).toBe(200);
  // The service's labels are not on the tenant's device, so the service cannot reach it.
  expect((await harness.request(`/v1/devices/${deviceId}`, as(key))).status).toBe(404);
  expect((await harness.request(`/v1/devices/${deviceId}`, bearer(owner), { method: "DELETE" })).status).toBe(204);
});
