import { describe, expect, it } from "vitest";
import { platformUserIdFor } from "../src/machine";
import { Device, auditEvents, mockOutbound, platformMachines, rawCall, signIn } from "./helpers";

/**
 * Joining is the consent (cmuxterm-hq docs/design/remote-screen-share-zero-touch.md, Z4): a
 * machine the person joined turns its Mac Screen sharing on from its own machine sign-in, and a
 * person's explicit off always wins over that, for every later join or update.
 */

async function joinedMachine(sub: string) {
  const credential = `cmm_${crypto.randomUUID().replace(/-/g, "")}`;
  platformMachines.set(credential, {
    machineId: `machine_${crypto.randomUUID().slice(0, 8)}`,
    teamId: "team_01",
    userId: await platformUserIdFor("test-project", sub),
    expiresAt: new Date(Date.now() + 30 * 24 * 3600 * 1000).toISOString(),
  });
  return credential;
}

/** The joined machine's own device, signed in with its machine credential (not registered yet). */
async function machineDevice(person: { userId: string }, credential: string, platform: "macos" | "linux" = "macos") {
  const host = await Device.create({ userId: person.userId, session: "" }, "Mini", platform);
  mockOutbound();
  const res = await rawCall("POST", "/v1/auth/machine", { body: { credential, deviceId: host.id } });
  expect(res.status, JSON.stringify(res.json)).toBe(200);
  const machine = await Device.create({ userId: res.json.userId, session: res.json.session }, "Mini", platform);
  Object.assign(machine, { id: host.id, signing: host.signing, signingKey: host.signingKey, agreementKey: host.agreementKey });
  return machine;
}

/** `POST /v1/devices` from `d`, with `shareByJoin` when given. */
async function registerAs(d: Device, shareByJoin?: boolean) {
  const body: Record<string, unknown> = { id: d.id, name: d.name, platform: d.platform, signingKey: d.signingKey, agreementKey: d.agreementKey };
  if (shareByJoin !== undefined) body.shareByJoin = shareByJoin;
  const res = await d.call("POST", "/v1/devices", body);
  expect(res.status, JSON.stringify(res.json)).toBe(200);
  return res.json.device;
}

async function listed(viewer: Device, id: string) {
  return (await viewer.call("GET", "/v1/devices")).json.devices.find((d: any) => d.id === id);
}

describe("join turns Mac Screen sharing on", () => {
  it("a joined machine's own sign-in with shareByJoin shares it at once, and the person's laptop sees it", async () => {
    const person = await signIn();
    const mini = await machineDevice(person, await joinedMachine(person.sub));
    expect((await registerAs(mini, true)).macScreenShared).toBe(true);
    const laptop = await Device.create(person, "Laptop", "macos");
    await laptop.register();
    expect(await listed(laptop, mini.id)).toMatchObject({ macScreenShared: true });
    expect(await auditEvents(laptop)).toContain("shared");
  });

  it("a person's explicit off always wins: no later join or update turns it back on", async () => {
    const person = await signIn();
    const credential = await joinedMachine(person.sub);
    const mini = await machineDevice(person, credential);
    expect((await registerAs(mini, true)).macScreenShared).toBe(true);
    // The person turns it off (the off switch on that Mac, or `cmux remote-host share off`).
    const off = await mini.call("PUT", `/v1/devices/${mini.id}/mac-screen`, { shared: false });
    expect(off.json.device.macScreenShared).toBe(false);
    // A daemon restart, an update and a second join all register again with shareByJoin.
    expect((await registerAs(mini, true)).macScreenShared).toBe(false);
    const rejoined = await machineDevice(person, credential);
    Object.assign(rejoined, { id: mini.id, signing: mini.signing, signingKey: mini.signingKey, agreementKey: mini.agreementKey });
    expect((await registerAs(rejoined, true)).macScreenShared).toBe(false);
    const laptop = await Device.create(person, "Laptop", "macos");
    await laptop.register();
    expect(await listed(laptop, mini.id)).toMatchObject({ macScreenShared: false });
  });

  it("an explicit off made before the join default ever applied also wins", async () => {
    const person = await signIn();
    const mini = await machineDevice(person, await joinedMachine(person.sub));
    expect((await registerAs(mini)).macScreenShared).toBe(false);
    await mini.call("PUT", `/v1/devices/${mini.id}/mac-screen`, { shared: false });
    expect((await registerAs(mini, true)).macScreenShared).toBe(false);
  });

  it("a Mac only signed in through the app never gets it, even when it asks", async () => {
    const person = await signIn();
    const mac = await Device.create(person, "Studio", "macos");
    expect((await registerAs(mac, true)).macScreenShared).toBe(false);
    expect((await registerAs(mac)).macScreenShared).toBe(false);
  });

  it("a joined machine that does not ask, or a phone, stays off", async () => {
    const person = await signIn();
    const mini = await machineDevice(person, await joinedMachine(person.sub));
    expect((await registerAs(mini, false)).macScreenShared).toBe(false);
    expect((await registerAs(mini)).macScreenShared).toBe(false);
    const res = await mini.call("POST", "/v1/devices", { id: mini.id, name: "x", platform: "macos", signingKey: mini.signingKey, agreementKey: mini.agreementKey, shareByJoin: "yes" });
    expect([res.status, res.json.error.code]).toEqual([400, "bad_request"]);
  });
});

describe("PUT /v1/devices/:id/screen-share", () => {
  const report = { state: "needs_grant", missing: ["screen_recording"], holder: "cmux NIGHTLY Screen Sharing", session: "this_user", osVersion: "26.1 (25B78)", checkedAtMs: 1, detail: "allow cmux NIGHTLY Screen Sharing under Privacy & Security > Screen Recording" };

  it("keeps a host's own status for every device's row", async () => {
    const person = await signIn();
    const mini = await machineDevice(person, await joinedMachine(person.sub));
    await registerAs(mini, true);
    const res = await mini.call("PUT", `/v1/devices/${mini.id}/screen-share`, { ...report, extra: "dropped" });
    expect(res.status, JSON.stringify(res.json)).toBe(200);
    const laptop = await Device.create(person, "Laptop", "macos");
    await laptop.register();
    const row = await listed(laptop, mini.id);
    expect(row.screenShare).toEqual({ schema: "cmux.screen-share.status/1", ...report });
    expect(row.screenShare.extra).toBeUndefined();
    // Another device cannot report it.
    const other = await laptop.call("PUT", `/v1/devices/${mini.id}/screen-share`, { ...report, state: "granted", missing: [] });
    expect([other.status, other.json.error.code]).toEqual([403, "not_host"]);
  });

  it("refuses a status outside the schema", async () => {
    const person = await signIn();
    const mac = await Device.create(person, "Studio", "macos");
    await mac.register();
    for (const bad of [
      { ...report, state: "maybe" },
      { ...report, missing: [] },
      { ...report, state: "granted" },
      { ...report, missing: ["camera"] },
      { ...report, missing: ["screen_recording", "screen_recording"] },
      { ...report, session: "everyone" },
      { ...report, checkedAtMs: "now" },
      { ...report, holder: "x".repeat(101) },
    ]) {
      const res = await mac.call("PUT", `/v1/devices/${mac.id}/screen-share`, bad);
      expect(res.status, JSON.stringify(bad)).toBe(400);
    }
    expect((await mac.call("GET", "/v1/devices")).json.devices[0].screenShare).toBeNull();
  });

  it("is not a phone's to report", async () => {
    const person = await signIn();
    const phone = await Device.create(person, "Phone", "ios");
    await phone.register();
    const res = await phone.call("PUT", `/v1/devices/${phone.id}/screen-share`, { ...report, state: "unsupported", missing: [] });
    expect([res.status, res.json.error.code]).toEqual([403, "not_host"]);
  });
});
