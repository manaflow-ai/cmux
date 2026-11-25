import { describe, expect, it } from "vitest";
import { machineIdFor } from "../src/userDo";
import { BASE, Device, signIn, worker } from "./helpers";

const MAC_KEY = "a".repeat(64);
const OTHER_MAC_KEY = "b".repeat(64);
const NIGHTLY = "com.cmuxterm.app.nightly";
const DEV = "com.cmuxterm.app.debug";

/** Registers `d` with a machine key and app id (what a cmux build sends). */
async function registerOn(d: Device, machineKey: string | undefined, appId: string | undefined) {
  return d.call("POST", "/v1/devices", {
    id: d.id,
    name: d.name,
    platform: d.platform,
    signingKey: d.signingKey,
    agreementKey: d.agreementKey,
    ...(machineKey === undefined ? {} : { machineKey }),
    ...(appId === undefined ? {} : { appId }),
  });
}

async function listed(d: Device): Promise<{ id: string; machineId: string | null; appId: string | null }[]> {
  const res = await d.call("GET", "/v1/devices");
  expect(res.status).toBe(200);
  return res.json.devices;
}

describe("one record per machine (machineKey, appId)", () => {
  it("a renewed install replaces its old offline record; the machine's other build stays", async () => {
    const account = await signIn();
    const phone = await Device.create(account, "iPhone", "ios");
    await phone.register();
    const nightly = await Device.create(account, "Desk Mac");
    const dev = await Device.create(account, "Desk Mac");
    expect((await registerOn(nightly, MAC_KEY, NIGHTLY)).status).toBe(200);
    expect((await registerOn(dev, MAC_KEY, DEV)).status).toBe(200);
    // NIGHTLY's id was refused (device_key_mismatch): it registers a new identity.
    const renewed = await Device.create(account, "Desk Mac");
    const res = await registerOn(renewed, MAC_KEY, NIGHTLY);
    expect(res.status, JSON.stringify(res.json)).toBe(200);
    const machineId = await machineIdFor(account.userId, MAC_KEY);
    expect(res.json.device).toMatchObject({ machineId, appId: NIGHTLY });
    const ids = (await listed(phone)).map((d) => d.id);
    expect(ids).toContain(renewed.id);
    expect(ids).toContain(dev.id); // DEV still uses its record: never retired by NIGHTLY
    expect(ids).not.toContain(nightly.id);
    // DEV registering again keeps NIGHTLY's new record: no ping-pong.
    expect((await registerOn(dev, MAC_KEY, DEV)).status).toBe(200);
    expect((await listed(phone)).map((d) => d.id)).toContain(renewed.id);
    // The retired record is removed like a DELETE: it cannot sign in again, and History says why.
    expect((await nightly.call("GET", "/v1/devices")).json.error.code).toBe("device_removed");
    const audit = await phone.call("GET", "/v1/audit");
    const entry = audit.json.entries.find((e: any) => e.event === "device_removed" && e.deviceId === nightly.id);
    expect(entry.detail).toContain(`replaced by ${renewed.id}`);
  });

  it("a record still online is kept until a later registration finds it offline", async () => {
    const account = await signIn();
    const old = await Device.create(account, "Desk Mac");
    expect((await registerOn(old, MAC_KEY, NIGHTLY)).status).toBe(200);
    await old.connect();
    const fresh = await Device.create(account, "Desk Mac");
    expect((await registerOn(fresh, MAC_KEY, NIGHTLY)).status).toBe(200);
    expect((await listed(fresh)).map((d) => d.id)).toContain(old.id);
    expect((await old.call("POST", `/v1/devices/${old.id}/sign-out`)).status).toBe(200);
    expect((await registerOn(fresh, MAC_KEY, NIGHTLY)).status).toBe(200);
    expect((await listed(fresh)).map((d) => d.id)).not.toContain(old.id);
  });

  it("another machine, another app id, or no machine fields never retire a record", async () => {
    const account = await signIn();
    const a = await Device.create(account, "Desk Mac");
    const b = await Device.create(account, "Desk Mac");
    const legacy = await Device.create(account, "Desk Mac");
    expect((await registerOn(a, MAC_KEY, NIGHTLY)).status).toBe(200);
    expect((await registerOn(legacy, undefined, undefined)).status).toBe(200);
    // Another Mac with the same Computer Name and build.
    expect((await registerOn(b, OTHER_MAC_KEY, NIGHTLY)).status).toBe(200);
    const devices = await listed(a);
    expect(devices.map((d) => d.id)).toEqual(expect.arrayContaining([a.id, b.id, legacy.id]));
    expect(devices.find((d) => d.id === a.id)!.machineId).not.toBe(devices.find((d) => d.id === b.id)!.machineId);
    expect(devices.find((d) => d.id === legacy.id)).toMatchObject({ machineId: null, appId: null });
  });

  it("a host session's registration retires nothing", async () => {
    const account = await signIn();
    const old = await Device.create(account, "Desk Mac");
    const mac = await Device.create(account, "Desk Mac");
    expect((await registerOn(old, MAC_KEY, NIGHTLY)).status).toBe(200);
    // `mac` registers first without machine fields, then anchors and renews a host session.
    expect((await registerOn(mac, undefined, undefined)).status).toBe(200);
    expect((await mac.call("PUT", `/v1/devices/${mac.id}/mac-screen`, { shared: true })).status).toBe(200);
    expect((await mac.call("POST", "/v1/auth/device/anchor", {})).status).toBe(200);
    const body = JSON.stringify({ userId: account.userId });
    const headers = { ...(await mac.headers("POST", "/v1/auth/device", body)), "content-type": "application/json" };
    const renewed = await worker.fetch(`${BASE}/v1/auth/device`, { method: "POST", headers, body });
    expect(renewed.status).toBe(200);
    const host = ((await renewed.json()) as { session: string }).session;
    const res = await mac.call(
      "POST",
      "/v1/devices",
      { id: mac.id, name: mac.name, platform: mac.platform, signingKey: mac.signingKey, agreementKey: mac.agreementKey, machineKey: MAC_KEY, appId: NIGHTLY },
      { session: host },
    );
    expect(res.status, JSON.stringify(res.json)).toBe(200);
    expect((await listed(mac)).map((d) => d.id)).toContain(old.id);
  });

  it("an older build's registration keeps the machine fields a newer one recorded", async () => {
    const account = await signIn();
    const mac = await Device.create(account, "Desk Mac");
    expect((await registerOn(mac, MAC_KEY, NIGHTLY)).status).toBe(200);
    const res = await registerOn(mac, undefined, undefined);
    expect(res.json.device).toMatchObject({ machineId: await machineIdFor(account.userId, MAC_KEY), appId: NIGHTLY });
  });

  it("the machine id is per account", async () => {
    const one = await signIn();
    const two = await signIn();
    expect(await machineIdFor(one.userId, MAC_KEY)).not.toBe(await machineIdFor(two.userId, MAC_KEY));
    const d = await Device.create(two, "Desk Mac");
    const res = await registerOn(d, MAC_KEY, NIGHTLY);
    expect(res.json.device.machineId).toBe(await machineIdFor(two.userId, MAC_KEY));
    expect(res.json.device.machineId).not.toContain(MAC_KEY);
  });

  it("refuses a malformed machineKey or appId", async () => {
    const account = await signIn();
    const d = await Device.create(account, "Desk Mac");
    for (const [machineKey, appId] of [["ABC", NIGHTLY], ["A".repeat(64), NIGHTLY], [MAC_KEY, ""], [MAC_KEY, "x".repeat(201)]] as const) {
      const res = await registerOn(d, machineKey, appId);
      expect(res.status, `${machineKey} ${appId}`).toBe(400);
      expect(res.json.error.code).toBe("bad_request");
    }
  });
});
