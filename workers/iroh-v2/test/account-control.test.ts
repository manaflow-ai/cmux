import { afterAll, beforeAll, expect, test } from "bun:test";
import { AccountBroker, type AccountSession } from "../src/account-broker";
import type { AccountResponse } from "../src/contracts/account";
import type { DeviceDescriptor } from "../src/contracts/common";
import type { SocketSetup } from "../src/contracts/requests";
import { accountRequestSigningInput, requestSigningInput } from "../src/crypto";
import { AccountStore } from "../src/storage/account-store";
import type { TeamStore } from "../src/storage/team-store";
import { sqliteStorage } from "./support/sqlite-storage";
import { RELAY_URL, deterministicRandom, descriptor, deviceKey, identity, sign, teamHarness, type DeviceKey } from "./support/team-fixture";

const NOW = 1_800_000_000;
const HOST = ["cmux.mac-host.v1", "cmux.mac-devices.v1"];
let restore: () => void;
beforeAll(() => { restore = deterministicRandom(); });
afterAll(() => restore());

/** Two teams and one account object for user-u, with the team RPC served from the real TeamStores. */
async function world() {
  let clock = NOW;
  const now = () => clock;
  const teams = new Map<string, TeamStore>();
  const x = await teamHarness("team-x", now), y = await teamHarness("team-y", now);
  teams.set("team-x", x.store); teams.set("team-y", y.store);
  const calls: string[] = [];
  const account = (userId: string, store = new AccountStore(sqliteStorage())) => new AccountBroker({
    store, userId, now, relayURLs: [RELAY_URL],
    teamRecords: async (teamId, identities) => {
      calls.push(teamId);
      const team = teams.get(teamId);
      if (!team) throw new Error("no team");
      return identities.map(value => team.accountMacRecord(value));
    },
  });
  return { x, y, now, setClock: (value: number) => { clock = value; }, account, calls };
}

async function accountSetup(key: DeviceKey, device: DeviceDescriptor, requestId: string, issuedAt: number, request?: unknown, nonce = "B".repeat(21) + requestId.length % 10) {
  const plain = { schemaId: "session.open.v1" as const, requestId, device };
  const body = request === undefined ? plain : { setup: plain, request };
  return { ...plain, proof: { requestId, nonce, issuedAt, signature: await sign(key, accountRequestSigningInput(device, requestId, issuedAt, body, nonce)) } } satisfies SocketSetup;
}

let nonceCounter = 0;
async function call(broker: AccountBroker, key: DeviceKey, device: DeviceDescriptor, schemaId: string, at = NOW): Promise<{ response: AccountResponse; changed?: number; session: AccountSession }> {
  const requestId = `${schemaId}-${++nonceCounter}`;
  const request = { schemaId, requestId };
  const nonce = String(nonceCounter).padStart(22, "N");
  const setup = await accountSetup(key, device, requestId, at, request, nonce);
  const authority = { environment: device.identity.environment, projectId: device.identity.projectId, teamId: device.identity.teamId, userId: device.identity.userId, verifiedAt: at - 10 };
  const { session } = await broker.authorize(setup, request, authority, at + 3590);
  return { ...(await broker.execute(session, request)), session };
}

function directoryOf(response: AccountResponse) {
  if (response.schemaId !== "account.directory.result.v1") throw new Error(`expected a directory, got ${JSON.stringify(response)}`);
  return response.directory;
}

test("a Mac that switches team X to Y replaces its row; its other Mac sees the Y endpoint and admits it", async () => {
  const w = await world();
  const [aKey, bKey] = await Promise.all([21, 22].map(deviceKey));
  const aInX = descriptor(aKey!, identity("team-x", "user-u", "mac-a"), "mac", HOST);
  const aInY = descriptor(aKey!, identity("team-y", "user-u", "mac-a"), "mac", HOST, true);
  const bInY = descriptor(bKey!, identity("team-y", "user-u", "mac-b"), "mac", HOST);
  w.x.enroll(aInX, NOW - 100); w.y.enroll(aInY, NOW - 100); w.y.enroll(bInY, NOW - 100);
  w.x.store.observeAuthority("user-u", NOW - 50, NOW + 3550, NOW);
  w.y.store.observeAuthority("user-u", NOW - 40, NOW + 3560, NOW);
  const broker = w.account("user-u");

  const first = await call(broker, aKey!, aInX, "account.publish.v1");
  expect(first.response).toMatchObject({ schemaId: "account.published.v1", revision: 1 });
  expect(first.changed).toBe(1);
  expect((await call(broker, bKey!, bInY, "account.publish.v1")).changed).toBe(2);
  let seen = directoryOf((await call(broker, bKey!, bInY, "account.directory.v1")).response);
  expect(seen.macs.map(mac => mac.descriptor.identity.teamId)).toEqual(["team-x"]);

  // Team switch: same installation (deviceId, namespace, build), new team.
  await call(broker, aKey!, aInY, "account.publish.v1");
  seen = directoryOf((await call(broker, bKey!, bInY, "account.directory.v1")).response);
  expect(seen.userId).toBe("user-u");
  expect(seen.rules).toEqual(["cmux.mac-account-peer.v1"]);
  expect(seen.macs.map(mac => [mac.descriptor.identity.teamId, mac.descriptor.endpointId])).toEqual([["team-y", aKey!.endpointId]]);
  expect(seen.inboundMacs.map(peer => [peer.device.descriptor.identity.deviceId, peer.permissionExpiresAt])).toEqual([["mac-a", NOW + 3560]]);
  expect(seen.permissionExpiresAt).toBe(NOW + 3590);
  // A's own view never lists A.
  const fromA = directoryOf((await call(broker, aKey!, aInY, "account.directory.v1")).response);
  expect(fromA.macs.map(mac => mac.descriptor.identity.deviceId)).toEqual(["mac-b"]);
});

test("scope comes only from the account object's user: another user's ticket cannot reach it", async () => {
  const w = await world();
  const tKey = await deviceKey(31);
  const teammate = descriptor(tKey, identity("team-x", "user-t", "mac-t"), "mac", HOST);
  w.x.enroll(teammate, NOW - 100);
  const broker = w.account("user-u");
  await expect(call(broker, tKey, teammate, "account.directory.v1")).rejects.toMatchObject({ code: "identity_mismatch" });
  // A teammate's own account object holds nothing of user-u.
  const own = directoryOf((await call(w.account("user-t"), tKey, teammate, "account.directory.v1")).response);
  expect(own.macs).toEqual([]);
  expect(own.inboundMacs).toEqual([]);
});

test("revoked and rekeyed rows drop on read; withdraw works even after revocation", async () => {
  const w = await world();
  const [aKey, bKey, cKey] = await Promise.all([41, 42, 43].map(deviceKey));
  const a = descriptor(aKey!, identity("team-x", "user-u", "mac-a"), "mac", HOST);
  const b = descriptor(bKey!, identity("team-x", "user-u", "mac-b"), "mac", HOST);
  const c = descriptor(cKey!, identity("team-y", "user-u", "mac-c"), "mac", HOST);
  const aRecord = w.x.enroll(a, NOW - 100); w.x.enroll(b, NOW - 100); w.y.enroll(c, NOW - 100);
  w.x.store.observeAuthority("user-u", NOW - 50, NOW + 3550, NOW);
  const broker = w.account("user-u");
  for (const [key, device] of [[aKey!, a], [bKey!, b], [cKey!, c]] as const) await call(broker, key, device, "account.publish.v1");
  w.x.store.revokeDevice(aRecord.deviceRecordId, NOW, "user-u");
  const seen = directoryOf((await call(broker, bKey!, b, "account.directory.v1")).response);
  expect(seen.macs.map(mac => mac.descriptor.identity.deviceId)).toEqual(["mac-c"]);
  // mac-c's team has no authority lease for user-u: listed outbound, not admitted inbound.
  expect(seen.inboundMacs).toEqual([]);
  await expect(call(broker, aKey!, a, "account.publish.v1")).rejects.toMatchObject({ code: "device_revoked" });
  const withdrawn = await call(broker, cKey!, c, "account.withdraw.v1");
  expect(withdrawn.response.schemaId).toBe("account.withdrawn.v1");
  expect(directoryOf((await call(broker, bKey!, b, "account.directory.v1")).response).macs).toEqual([]);
});

test("publish requires a Mac record with a Mac capability, matching key, and teamChanged revalidates", async () => {
  const w = await world();
  const [phoneKey, plainKey, aKey, bKey] = await Promise.all([51, 52, 53, 54].map(deviceKey));
  const phone = descriptor(phoneKey!, identity("team-x", "user-u", "iphone"), "ios", HOST);
  const plain = descriptor(plainKey!, identity("team-x", "user-u", "mac-plain"), "mac", []);
  const a = descriptor(aKey!, identity("team-x", "user-u", "mac-a"), "mac", HOST);
  const b = descriptor(bKey!, identity("team-x", "user-u", "mac-b"), "mac", HOST);
  w.x.enroll(phone, NOW - 100); w.x.enroll(plain, NOW - 100); w.x.enroll(b, NOW - 100);
  const broker = w.account("user-u");
  await expect(call(broker, phoneKey!, phone, "account.publish.v1")).rejects.toMatchObject({ code: "permission_denied" });
  await expect(call(broker, plainKey!, plain, "account.publish.v1")).rejects.toMatchObject({ code: "permission_denied" });
  await expect(call(broker, aKey!, a, "account.publish.v1")).rejects.toMatchObject({ code: "device_not_enrolled" });
  const aRecord = w.x.enroll(a, NOW - 100);
  await call(broker, aKey!, a, "account.publish.v1");
  w.x.store.updateMetadata(a.identity, { ...a.metadata, capabilities: [] }, NOW);
  expect(await broker.teamChanged("team-x", aRecord.deviceRecordId)).not.toBeNull();
  expect(directoryOf((await call(broker, bKey!, b, "account.directory.v1")).response).macs).toEqual([]);
  expect(await broker.teamChanged("team-x", "unrelated-record")).toBeNull();
});

test("namespace, build tag and lease gate inbound admission", async () => {
  const w = await world();
  const [hostKey, sameKey, otherBuildKey, otherNamespaceKey] = await Promise.all([61, 62, 63, 64].map(deviceKey));
  const host = descriptor(hostKey!, identity("team-x", "user-u", "host"), "mac", HOST);
  const same = descriptor(sameKey!, identity("team-y", "user-u", "same"), "mac", ["cmux.mac-devices.v1"]);
  const otherBuild = descriptor(otherBuildKey!, identity("team-y", "user-u", "build", { buildTag: "dev" }), "mac", HOST);
  const otherNamespace = descriptor(otherNamespaceKey!, identity("team-y", "user-u", "ns", { appNamespace: "dev.cmux.app.beta" }), "mac", HOST);
  for (const device of [host]) w.x.enroll(device, NOW - 100);
  for (const device of [same, otherBuild, otherNamespace]) w.y.enroll(device, NOW - 100);
  w.x.store.observeAuthority("user-u", NOW - 50, NOW + 3550, NOW);
  w.y.store.observeAuthority("user-u", NOW - 3000, NOW + 600, NOW);
  const broker = w.account("user-u");
  for (const [key, device] of [[hostKey!, host], [sameKey!, same], [otherBuildKey!, otherBuild], [otherNamespaceKey!, otherNamespace]] as const) await call(broker, key, device, "account.publish.v1");
  const seen = directoryOf((await call(broker, hostKey!, host, "account.directory.v1")).response);
  expect(seen.macs.map(mac => mac.descriptor.identity.deviceId)).toEqual(["build"]);
  expect(seen.inboundMacs.map(peer => peer.device.descriptor.identity.deviceId)).toEqual(["same"]);
  // A requester without mac-host never receives inbound admissions.
  expect(directoryOf((await call(broker, sameKey!, same, "account.directory.v1")).response).inboundMacs).toEqual([]);
  // Lease lapses in team-y: still listed outbound, no longer admitted.
  w.setClock(NOW + 700);
  const later = directoryOf((await call(broker, hostKey!, host, "account.directory.v1", NOW + 700)).response);
  expect(later.inboundMacs).toEqual([]);
});

test("proofs: replayed nonces and team-purpose signatures are rejected", async () => {
  const w = await world();
  const aKey = await deviceKey(71);
  const a = descriptor(aKey, identity("team-x", "user-u", "mac-a"), "mac", HOST);
  w.x.enroll(a, NOW - 100);
  const broker = w.account("user-u");
  const authority = { environment: a.identity.environment, projectId: a.identity.projectId, teamId: "team-x", userId: "user-u", verifiedAt: NOW };
  const request = { schemaId: "account.directory.v1", requestId: "replayed" };
  const setup = await accountSetup(aKey, a, "replayed", NOW, request, "R".repeat(22));
  await broker.authorize(setup, request, authority, NOW + 3600);
  await expect(broker.authorize(setup, request, authority, NOW + 3600)).rejects.toMatchObject({ code: "proof_replayed" });
  const plain = { schemaId: "session.open.v1" as const, requestId: "team-purpose", device: a };
  const teamRequest = { schemaId: "account.directory.v1", requestId: "team-purpose" };
  const nonce = "T".repeat(22);
  const teamSigned = { ...plain, proof: { requestId: "team-purpose", nonce, issuedAt: NOW, signature: await sign(aKey, requestSigningInput(a, "team-purpose", NOW, { setup: plain, request: teamRequest }, nonce)) } };
  await expect(broker.authorize(teamSigned, teamRequest, authority, NOW + 3600)).rejects.toMatchObject({ code: "invalid_device_proof" });
  await expect(broker.authorize(await accountSetup(aKey, a, "stale", NOW - 61, undefined, "S".repeat(22)), undefined, authority, NOW + 3600)).rejects.toMatchObject({ code: "invalid_device_proof" });
});

test("the account object holds at most 16 Macs and evicts only lapsed leases", async () => {
  const w = await world();
  const broker = w.account("user-u");
  w.x.store.observeAuthority("user-u", NOW - 50, NOW + 3550, NOW);
  const devices: [DeviceKey, DeviceDescriptor][] = [];
  for (let index = 0; index < 17; index++) {
    const key = await deviceKey(100 + index);
    const device = descriptor(key, identity("team-x", "user-u", `mac-${index}`), "mac", HOST);
    w.x.enroll(device, NOW - 100);
    devices.push([key, device]);
  }
  for (const [key, device] of devices.slice(0, 16)) await call(broker, key, device, "account.publish.v1");
  await expect(call(broker, devices[16]![0], devices[16]![1], "account.publish.v1")).rejects.toMatchObject({ code: "device_limit" });
  w.setClock(NOW + 4000);
  await call(broker, devices[16]![0], devices[16]![1], "account.publish.v1", NOW + 4000);
});
