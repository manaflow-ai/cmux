import { runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { STALE_SIBLING_MS } from "../src/userDo";
import { Device, auditEvents, hubEnv, signIn } from "./helpers";

/**
 * One machine is one device (Leo, 2026-11-18: "i should be able to see into any connected mac or
 * linux machine"). A Mac registered twice, the app's device and the acpmux daemon's, and kept every
 * older identity of the app; the list showed it several times and a name like `studio-mac` was
 * ambiguous. Every registrant now names the same `machine`; a registration removes the stale
 * devices of its machine, and the list says which devices are one machine (`machineGroup`).
 */
const MAC = "d".repeat(64);
const OTHER_MAC = "e".repeat(64);

async function device(account: Awaited<ReturnType<typeof signIn>>, name: string, machine?: string, platform: "macos" | "ios" | "linux" = "macos") {
  const d = await Device.create(account, name, platform);
  d.machine = machine;
  await d.register();
  return d;
}

/** Makes `d` look unheard for longer than the stale bound. */
async function age(userId: string, d: Device) {
  const stub = hubEnv.USER_DO.get(hubEnv.USER_DO.idFromName(userId));
  await runInDurableObject(stub, (_i, state) => {
    state.storage.sql.exec("UPDATE devices SET last_seen_at = ? WHERE id = ?", Date.now() - STALE_SIBLING_MS - 1000, d.id);
  });
}

async function listed(viewer: Device) {
  return (await viewer.call("GET", "/v1/devices")).json.devices as any[];
}

describe("one machine, one device", () => {
  it("the daemon's registration removes the app's stale identities of the same Mac", async () => {
    const account = await signIn();
    const viewer = await device(account, "Laptop", OTHER_MAC);
    const oldApp = await device(account, "Studio Mac", MAC);
    const olderApp = await device(account, "Studio Mac", MAC);
    await age(account.userId, oldApp);
    await age(account.userId, olderApp);
    const daemon = await device(account, "studio-mac", MAC);
    const ids = (await listed(viewer)).map((d) => d.id);
    expect(ids).toContain(daemon.id);
    expect(ids).not.toContain(oldApp.id);
    expect(ids).not.toContain(olderApp.id);
    // The removed ids are gone for good, as a person's Remove leaves them.
    expect((await oldApp.call("GET", "/v1/me")).json.error.code).toBe("device_removed");
    expect(await auditEvents(viewer)).toContain("device_removed");
  });

  it("keeps a sibling that is online or was heard within the bound (another build running now)", async () => {
    const account = await signIn();
    const running = await device(account, "Studio", MAC);
    await running.connect();
    await age(account.userId, running);
    const justRegistered = await device(account, "Studio", MAC);
    const third = await device(account, "Studio", MAC);
    const ids = (await listed(third)).map((d) => d.id);
    expect(ids).toEqual(expect.arrayContaining([running.id, justRegistered.id, third.id]));
  });

  it("never removes another machine's device, a device that named none, or another platform", async () => {
    const account = await signIn();
    const other = await device(account, "Studio", OTHER_MAC);
    const unnamed = await device(account, "Studio");
    const phone = await device(account, "Studio", MAC, "ios");
    for (const d of [other, unnamed, phone]) await age(account.userId, d);
    const mac = await device(account, "Studio", MAC);
    const ids = (await listed(mac)).map((d) => d.id);
    expect(ids).toEqual(expect.arrayContaining([other.id, unnamed.id, phone.id, mac.id]));
  });

  it("moves a stale identity's permissions and sharing switch to the new one: no removal raises access", async () => {
    const account = await signIn();
    const viewer = await device(account, "Laptop", OTHER_MAC);
    const oldHost = await device(account, "Studio Mac", MAC);
    // The person said None for Laptop on this Mac, and turned its sharing off.
    expect((await oldHost.call("PUT", `/v1/permissions/${oldHost.id}/${viewer.id}`, { scope: "none" })).status).toBe(200);
    await oldHost.share(false);
    await age(account.userId, oldHost);
    const daemon = await device(account, "studio-mac", MAC);
    const perms = (await daemon.call("GET", `/v1/permissions?host=${daemon.id}`)).json.permissions;
    expect(perms).toContainEqual({ viewerId: viewer.id, scope: "none" });
    expect((await listed(viewer)).find((d) => d.id === daemon.id)).toMatchObject({ macScreenShared: false });
  });

  it("lists one machineGroup for every device of a machine, never the machine itself", async () => {
    const account = await signIn();
    const app = await device(account, "Studio Mac", MAC);
    const daemon = await device(account, "studio-mac", MAC);
    const other = await device(account, "Laptop", OTHER_MAC);
    const unnamed = await device(account, "Phone", undefined, "ios");
    const rows = await listed(other);
    const group = (d: Device) => rows.find((r) => r.id === d.id)?.machineGroup;
    expect(group(app)).toMatch(/^[0-9a-f]{32}$/);
    expect(group(daemon)).toBe(group(app));
    expect(group(other)).not.toBe(group(app));
    expect(group(unnamed)).toBeNull();
    expect(JSON.stringify(rows)).not.toContain(MAC);
  });
});

/**
 * Same-account sharing with no Allow (Leo, 2026-11-18: "the whole allow blah blah is so annoying"):
 * a host turns it on with `shareWithOwnDevices` at registration, from its setting
 * `remote.shareWithOwnDevicesByDefault` (on by default). Without it the hub does what it did
 * before: an unset switch is off unless a join turned it on.
 */
async function host(account: Awaited<ReturnType<typeof signIn>>, name: string, shareWithOwnDevices: boolean | undefined, platform: "macos" | "ios" | "linux" = "macos") {
  const d = await Device.create(account, name, platform);
  d.machine = platform === "ios" ? undefined : MAC;
  d.shareWithOwnDevices = shareWithOwnDevices;
  await d.register();
  return d;
}

describe("sharing with your own devices by default (remote.shareWithOwnDevicesByDefault)", () => {
  it("off (not sent, or false): an own Mac whose switch was never set does not share", async () => {
    const account = await signIn();
    for (const flag of [undefined, false]) {
      const mac = await host(account, "Studio", flag);
      const viewer = await device(account, "Laptop", OTHER_MAC);
      expect((await listed(viewer)).find((d) => d.id === mac.id)).toMatchObject({ macScreenShared: false });
      await mac.connect();
      expect((await viewer.call("POST", "/v1/sessions", { hostId: mac.id, scope: "view" })).json.error.code).toBe("not_shared");
    }
  });

  it("on: views and controls an own Mac whose switch was never set, and Stop and Revoke still end it", async () => {
    const account = await signIn();
    const mac = await host(account, "studio-mac", true);
    await mac.connect();
    const viewer = await device(account, "Laptop", OTHER_MAC);
    await viewer.connect();
    const res = await viewer.call("POST", "/v1/sessions", { hostId: mac.id, scope: "full" });
    expect(res.status, JSON.stringify(res.json)).toBe(200);
    expect(res.json.session.state).toBe("approved");
    expect(await mac.user!.none((f) => f.type === "session.request")).toBe(true);
    // Stop: the host turns sharing off; the session ends and no new one starts.
    await mac.share(false);
    expect(await viewer.user!.next((f) => f.type === "session.revoked" && f.sessionId === res.json.session.id)).toMatchObject({ reason: "sharing_off" });
    expect((await viewer.call("POST", "/v1/sessions", { hostId: mac.id, scope: "view" })).json.error.code).toBe("not_shared");
    // The explicit off wins over the setting at every later registration.
    expect((await mac.register()).json.device.macScreenShared).toBe(false);
    // On again, then Revoke: the person's None refuses this viewer without a prompt.
    await mac.share(true);
    await mac.call("PUT", `/v1/permissions/${mac.id}/${viewer.id}`, { scope: "none" });
    expect((await viewer.call("POST", "/v1/sessions", { hostId: mac.id, scope: "view" })).json.error.code).toBe("permission_none");
  });

  it("on, then the setting turned off: the next registration stops the default", async () => {
    const account = await signIn();
    const mac = await host(account, "Studio", true);
    expect((await mac.register()).json.device.macScreenShared).toBe(true);
    mac.shareWithOwnDevices = false;
    expect((await mac.register()).json.device.macScreenShared).toBe(false);
  });

  it("on covers a Linux desktop; a phone never shares; a bad value is refused", async () => {
    const account = await signIn();
    const linux = await host(account, "Desk", true, "linux");
    expect((await linux.register()).json.device).toMatchObject({ platform: "linux", macScreenShared: true });
    const phone = await host(account, "Phone", true, "ios");
    expect((await listed(phone)).find((d) => d.id === phone.id)).toMatchObject({ platform: "ios", macScreenShared: false });
    const res = await phone.call("POST", "/v1/devices", { id: phone.id, name: "x", platform: "ios", signingKey: phone.signingKey, agreementKey: phone.agreementKey, shareWithOwnDevices: "yes" });
    expect([res.status, res.json.error.code]).toEqual([400, "bad_request"]);
  });
});
