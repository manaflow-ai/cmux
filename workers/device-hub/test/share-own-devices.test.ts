import { describe, expect, it } from "vitest";
import { Device, signIn } from "./helpers";

/**
 * Same-account sharing with no Allow (Leo, 2026-11-18: "the whole allow blah blah is so annoying"):
 * a host turns it on with `shareWithOwnDevices` at registration, from its setting
 * `remote.shareWithOwnDevicesByDefault` (on by default). Without it the hub does what it did
 * before: an unset switch is off unless a join turned it on.
 */
const MAC = "d".repeat(64);
const OTHER_MAC = "e".repeat(64);

async function device(account: Awaited<ReturnType<typeof signIn>>, name: string, machine?: string, platform: "macos" | "ios" | "linux" = "macos") {
  const d = await Device.create(account, name, platform);
  d.machine = machine;
  await d.register();
  return d;
}

async function listed(viewer: Device) {
  return (await viewer.call("GET", "/v1/devices")).json.devices as any[];
}

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
