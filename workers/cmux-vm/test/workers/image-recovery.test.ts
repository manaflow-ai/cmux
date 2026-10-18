import { afterEach, beforeEach, expect, it } from "vitest";
import { bearer } from "../support/endpoints.ts";
import { makeHarness } from "../support/harness.ts";

const IMAGE = { id: "cloud-standard", revision: "r1" };
const SNAPSHOT = "immutable-operator-image";
const CATALOG = [{ ...IMAGE, displayName: "Cloud standard", snapshotId: SNAPSHOT, services: ["cloud-driver"] }];
let h: Awaited<ReturnType<typeof makeHarness>>;
let key: string;
beforeEach(async () => {
  h = await makeHarness({ bootImages: JSON.stringify(CATALOG) });
  h.upstream.snapshots.set(SNAPSHOT, { id: SNAPSHOT, sourceVmId: "operator", autoDeleteSeconds: null });
  key = await h.addServiceKey({ id: "cloud-driver", labels: { role: "cloud" }, scopes: ["vm:read", "vm:write"] });
});
afterEach(async () => { await h.dispose(); });
const headers = (token = key, idempotency = "retained-image") => ({ ...bearer(token), "x-cmux-team-id": "team_alpha", "idempotency-key": idempotency });
const create = (extra: object = {}, idempotency = "retained-image", token = key) =>
  h.request("/v1/vms", headers(token, idempotency), { method: "POST", body: { image: IMAGE, labels: { role: "cloud" }, ...extra } });
const allocations = () => h.upstream.callsTo("POST", /^\/v5\/vms$/);
const withdraw = () => { h.setBootImages("[]"); h.upstream.snapshots.delete(SNAPSHOT); };

it("replays the admitted image receipt after catalog and backing snapshot removal", async () => {
  const first = await create(); expect(first.status).toBe(201);
  const original = await first.json();
  withdraw();
  const replay = await create(); expect(replay.status).toBe(201);
  expect(await replay.json()).toEqual(original);
  expect(allocations()).toHaveLength(1);
  expect(h.upstream.callsTo("GET", /^\/v5\/snapshots\//)).toHaveLength(1);
  expect((await create({}, "fresh-image")).status).toBe(404);
  expect(allocations()).toHaveLength(1);
});

it("recovers the old revision after catalog advancement but refuses a changed requested revision", async () => {
  const first = await create(); expect(first.status).toBe(201);
  h.setBootImages(JSON.stringify([{ ...CATALOG[0], revision: "r2", snapshotId: "new-immutable-image" }]));
  const replay = await create(); expect(replay.status).toBe(201);
  expect(await replay.json()).toEqual(await first.json());
  expect((await create({ image: { ...IMAGE, revision: "r2" } })).status).toBe(409);
  expect(allocations()).toHaveLength(1);
});

it("reconciles an unrecorded allocation after withdrawal without reading the removed source or allocating again", async () => {
  h.recordFault.before = 1;
  expect((await create()).status).toBe(503);
  withdraw();
  const replay = await create(); expect(replay.status).toBe(201);
  expect(await replay.json()).toMatchObject({ bootImage: IMAGE });
  expect(h.resources).toHaveLength(1);
  expect(h.upstream.vms.size).toBe(1);
  expect(allocations()).toHaveLength(1);
  expect(h.upstream.callsTo("GET", /^\/v5\/vms$/)).toHaveLength(0);
});

it.each([
  { displayName: "changed" }, { resources: { vcpus: 8 } }, { maxRunSeconds: 120 },
  { autoDeleteSeconds: 600 }, { idleTimeoutSeconds: 120 }, { labels: { role: "cloud", changed: "yes" } },
])("rejects changed request fields after withdrawal: %j", async (extra) => {
  expect((await create()).status).toBe(201);
  withdraw();
  expect((await create(extra)).status).toBe(409);
  expect(allocations()).toHaveLength(1);
});

it("keeps a deleted destination deleted after withdrawal", async () => {
  const first = await create(); expect(first.status).toBe(201);
  const { id } = await first.json<{ id: string }>();
  expect((await h.request(`/v1/vms/${id}`, headers(), { method: "DELETE" })).status).toBe(204);
  withdraw();
  expect((await create()).status).toBe(404);
  expect(h.upstream.vms.size).toBe(0);
  expect(allocations()).toHaveLength(1);
});

it("preserves the cancellation fence when the image is withdrawn", async () => {
  h.recordFault.before = 1;
  expect((await create()).status).toBe(503);
  const cancel = await h.request("/v1/vm-creations/by-key/cancel", headers(), { method: "POST" });
  expect(cancel.status).toBe(200);
  withdraw();
  expect((await create()).status).toBe(409);
  expect(h.upstream.vms.size).toBe(0);
  expect(allocations()).toHaveLength(1);
});

it("never sends again when an unknown allocation cannot be found after withdrawal", async () => {
  const fetch = h.upstream.fetch; let sends = 0;
  h.upstream.fetch = async (request) => {
    if (request.method === "POST" && new URL(request.url).pathname === "/v5/vms") { sends++; throw new TypeError("unknown create result"); }
    return fetch(request);
  };
  expect((await create()).status).toBe(503);
  withdraw();
  expect((await create()).status).toBe(503);
  expect(sends).toBe(1);
  expect(h.resources).toHaveLength(0);
});

it("keeps partial growth unresolved until the image is approved again, without reallocating", async () => {
  h.upstream.fail("resize", 503);
  expect((await create({ resources: { vcpus: 8 } })).status).toBe(503);
  withdraw();
  expect((await create({ resources: { vcpus: 8 } })).status).toBe(503);
  expect(h.upstream.callsTo("POST", /\/resize$/)).toHaveLength(1);
  expect(h.resources).toHaveLength(0);
  h.setBootImages(JSON.stringify(CATALOG));
  expect((await create({ resources: { vcpus: 8 } })).status).toBe(201);
  expect(h.upstream.callsTo("POST", /\/resize$/)).toHaveLength(2);
  expect(allocations()).toHaveLength(1);
});

it("keeps current scopes, service identity and team restrictions on withdrawn-image retries", async () => {
  expect((await create()).status).toBe(201);
  withdraw();
  const read = await h.addServiceKey({ id: "cloud-driver", labels: { role: "cloud" }, scopes: ["vm:read"] });
  const other = await h.addServiceKey({ id: "unrelated-driver", labels: { role: "cloud" } });
  const foreign = await h.addServiceKey({ id: "cloud-driver", labels: { role: "cloud" }, teams: ["team_bravo"] });
  expect((await create({}, "retained-image", read)).status).toBe(403);
  expect((await create({}, "retained-image", other)).status).toBe(404);
  expect((await create({}, "retained-image", foreign)).status).toBe(403);
  expect((await create({ labels: {} })).status).toBe(403);
  expect(allocations()).toHaveLength(1);
});

it.each(["provider", "source", "request", "labels"])("refuses changed recovery evidence after withdrawal: %s", async (changed) => {
  h.recordFault.before = 1;
  expect((await create()).status).toBe(503);
  withdraw();
  const vm = [...h.upstream.vms.values()][0]!;
  if (changed === "provider") h.setProviderConfig("https://another-provider.test", "different-fixture-key");
  if (changed === "source") vm.snapshotId = "unrelated-snapshot";
  if (changed === "request") vm.metadata["cmux_create"] = "unrelated-request";
  if (changed === "labels") {
    // A committed destination still needs the service's current resource labels.
    h.setBootImages(JSON.stringify(CATALOG));
    h.upstream.snapshots.set(SNAPSHOT, { id: SNAPSHOT, sourceVmId: "operator", autoDeleteSeconds: null });
    expect((await create()).status).toBe(201);
    Object.assign(h.resources[0]!, { labels: { role: "unrelated" } });
    withdraw();
  }
  expect((await create()).status).toBe(changed === "labels" ? 404 : 503);
  expect(allocations()).toHaveLength(1);
  expect(h.resources).toHaveLength(changed === "labels" ? 1 : 0);
});
