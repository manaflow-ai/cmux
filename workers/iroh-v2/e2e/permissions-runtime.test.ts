import { afterAll, beforeAll, expect, test } from "bun:test";
import { convertV4MiniflareOptions, Miniflare } from "miniflare";
import { join } from "node:path";

let mf: Miniflare;
let namespace: DurableObjectNamespace;
beforeAll(async () => {
  const root = `/tmp/iroh-v2-permissions-${Date.now()}`;
  const build = Bun.spawnSync(["bun", "build", join(import.meta.dir, "permissions-worker.ts"), "--outfile", root + "/worker.js", "--target", "browser"]);
  if (build.exitCode) throw new Error(new TextDecoder().decode(build.stderr));
  mf = new Miniflare(convertV4MiniflareOptions({ rootPath: root, resourcePersistencePath: root + "/storage", scriptPath: "worker.js", modules: true, compatibilityDate: "2026-09-10", durableObjects: { PERMISSIONS: { className: "PermissionTestDO", useSQLite: true } } }));
  namespace = await mf.getDurableObjectNamespace("PERMISSIONS");
});
afterAll(async () => { await mf?.dispose(); });
const client = (name: string) => async (path: string, input: unknown = {}) => {
  const response = await namespace.getByName(name).fetch("https://fixture.test" + path, { method: "POST", body: JSON.stringify(input) });
  return { status: response.status, body: await response.json() as any };
};
const names = (devices: any[]) => devices.map(device => device.descriptor.identity.deviceId).sort();

test("inbound permission targets this Mac and does not follow outgoing visibility", async () => {
  const post = client("direction");
  const result = await post("/directory");
  expect(result.status).toBe(200);
  expect(names(result.body.directory.devices)).toEqual(["mac-alice", "mac-bob", "phone-alice"]);
  expect(names(result.body.directory.inboundPeers.map((p: any) => p.device))).toEqual(["phone-alice", "phone-bob"]);
  const phone = await post("/directory", { device: "phone-bob" });
  expect(phone.body.directory.inboundPeers).toEqual([]);
  expect((await post("/authority", { user: "bob" })).body.stackCalls).toBe(0);
});

test("inbound authority expires exactly and ordinary directory reads cannot extend it", async () => {
  const post = client("expiry");
  const first = (await post("/directory")).body.directory;
  expect(first.inboundPeers.find((p: any) => p.device.descriptor.identity.userId === "bob").permissionExpiresAt).toBe(4600);
  await post("/time", { now: 4599 });
  expect(names((await post("/directory")).body.directory.inboundPeers.map((p: any) => p.device))).toContain("phone-bob");
  await post("/time", { now: 4600 });
  expect(names((await post("/directory")).body.directory.inboundPeers.map((p: any) => p.device))).toEqual(["phone-alice"]);
  expect((await post("/authority", { user: "bob" })).body.authority.expiresAt).toBe(4600);
  expect((await post("/renew", { device: "phone-bob" })).status).toBe(200);
  const renewed = (await post("/directory")).body.directory;
  expect(renewed.inboundPeers.find((p: any) => p.device.descriptor.identity.userId === "bob").permissionExpiresAt).toBe(4800);
  expect((await post("/authority", { user: "bob" })).body.stackCalls).toBe(1);
});

test("permission removal, device revocation and disabled pairing remove inbound grants", async () => {
  const post = client("removal");
  await post("/permission", { user: "bob", connect: false });
  expect(names((await post("/directory")).body.directory.inboundPeers.map((p: any) => p.device))).toEqual(["phone-alice"]);
  await post("/revoke", { device: "phone-alice" });
  expect((await post("/directory")).body.directory.inboundPeers).toEqual([]);
  await post("/permission", { user: "bob", connect: true });
  await post("/pairing", { enabled: false });
  expect((await post("/directory")).body.directory.inboundPeers).toEqual([]);
});

test("one keyset cursor covers visible devices and inbound-only peers without omission", async () => {
  const post = client("pagination");
  const rows: any[] = [];
  let cursor: string | undefined;
  for (let page = 0; page < 10; page++) {
    const result = await post("/page", { limit: 1, ...(cursor ? { cursor } : {}) });
    expect(result.status).toBe(200);
    if (!result.body.length) break;
    rows.push(...result.body); cursor = result.body.at(-1).device.deviceRecordId;
  }
  expect(names(rows.map(row => row.device))).toEqual(["mac-alice", "mac-bob", "phone-alice", "phone-bob"]);
  expect(rows.find(row => row.device.descriptor.identity.deviceId === "phone-bob").visible).toBe(false);
  const first = (await post("/directory")).body.directory;
  await post("/permission", { user: "bob", connect: false });
  const stale = await post("/directory", { cursor, revision: first.revision });
  expect(stale.status).toBe(409);
  expect(stale.body.code).toBe("resync_required");
});
