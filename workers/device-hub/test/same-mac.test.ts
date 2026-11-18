import { describe, expect, it } from "vitest";
import { Device, approvedSession, signIn } from "./helpers";

/**
 * An Always answer is about a Mac, not one identity of it. A Mac gets a new device id when a
 * tagged build runs (its own bundle id, so its own Keychain items) or when its identity renews
 * (the hub refused the old one), and the host's Always for that Mac used to stop applying: the
 * approval panel asked again for a Mac it had been told to always allow. The app sends a
 * `machine` at registration (a keyed hash of the Mac's hardware UUID, the same for every build); the
 * hub reads a permission across every live device of the same machine, the newest answer first.
 *
 * A device with no stored answer gets the account's own-device default, Full Control
 * (`OWN_DEVICE_DEFAULT`). So these tests give an Always View Only and probe with a Full Control
 * request: it waits for the host where the View Only answer covers the asking device, and is
 * admitted where it does not.
 */
const MAC_A = "a".repeat(64);
const MAC_B = "b".repeat(64);
const HOST_MAC = "c".repeat(64);

async function device(account: Awaited<ReturnType<typeof signIn>>, name: string, machine?: string, platform: "macos" | "ios" = "macos") {
  const d = await Device.create(account, name, platform);
  d.machine = machine;
  await d.register();
  await d.connect();
  return d;
}

async function pair(hostMachine: string | undefined = HOST_MAC) {
  const account = await signIn();
  const host = await device(account, "Laptop", hostMachine);
  await host.share(true);
  const viewer = await device(account, "Desk Mac", MAC_A);
  return { account, host, viewer };
}

/** The host sets the viewer to Ask; the viewer asks; the host answers Always with `scope`. */
async function alwaysAllow(host: Device, viewer: Device, scope: "view" | "full") {
  expect((await host.call("PUT", `/v1/permissions/${host.id}/${viewer.id}`, { scope: "ask" })).status).toBe(200);
  const res = await viewer.call("POST", "/v1/sessions", { hostId: host.id, scope });
  expect(res.json.session.state).toBe("pending");
  const decided = await host.call("POST", `/v1/sessions/${res.json.session.id}/decision`, { decision: "always", scope });
  expect(decided.status, JSON.stringify(decided.json)).toBe(200);
}

const ask = (viewer: Device, host: Device, scope: "view" | "full") => viewer.call("POST", "/v1/sessions", { hostId: host.id, scope });

describe("an Always answer covers the same Mac", () => {
  it("covers the Mac's next identity (a tagged build, a renewed identity) without asking again", async () => {
    const { account, host, viewer } = await pair();
    await alwaysAllow(host, viewer, "view");
    const sameMac = await device(account, "Desk Mac", MAC_A);
    const res = await ask(sameMac, host, "view");
    expect(res.status, JSON.stringify(res.json)).toBe(200);
    expect(res.json.session).toMatchObject({ state: "approved", scope: "view" });
    expect(await host.user!.none((f) => f.type === "session.request" && f.session.viewerId === sameMac.id)).toBe(true);
    // The answer covers it: Full Control waits for the host instead of the default.
    expect((await ask(sameMac, host, "full")).json.session.state).toBe("pending");
    // The Devices list shows the same access for it.
    const listed = (await host.call("GET", `/v1/permissions?host=${host.id}`)).json.permissions;
    expect(listed).toContainEqual({ viewerId: sameMac.id, scope: "view" });
  });

  it("survives the host's own new identity (an update that renewed it)", async () => {
    const { account, host, viewer } = await pair();
    await alwaysAllow(host, viewer, "view");
    const renewedHost = await device(account, "Laptop", HOST_MAC);
    await renewedHost.share(true);
    expect((await ask(viewer, renewedHost, "view")).json.session).toMatchObject({ state: "approved", scope: "view" });
    expect((await ask(viewer, renewedHost, "full")).json.session.state).toBe("pending");
  });

  it("never crosses to another Mac, or to a device that names no machine", async () => {
    const { account, host, viewer } = await pair();
    await alwaysAllow(host, viewer, "view");
    // Each gets the default, Full Control, not the View Only answer.
    const otherMac = await device(account, "Desk Mac", MAC_B);
    expect((await ask(otherMac, host, "full")).json.session.state).toBe("approved");
    const unnamed = await device(account, "Desk Mac");
    expect((await ask(unnamed, host, "full")).json.session.state).toBe("approved");
    const phone = await device(account, "Desk Mac", MAC_A, "ios");
    expect((await ask(phone, host, "full")).json.session.state).toBe("approved");
  });

  it("covers only what it includes: Always View Only still asks for Full Control", async () => {
    const { account, host, viewer } = await pair();
    await alwaysAllow(host, viewer, "view");
    const sameMac = await device(account, "Desk Mac", MAC_A);
    expect((await ask(sameMac, host, "view")).json.session.state).toBe("approved");
    expect((await ask(sameMac, host, "full")).json.session.state).toBe("pending");
  });

  it("takes the newest answer about the Mac, and lowering it ends that Mac's sessions above it", async () => {
    const { account, host, viewer } = await pair();
    const sameMac = await device(account, "Desk Mac", MAC_A);
    const { sid } = await approvedSession(host, viewer, "full");
    // The host lowers the other identity's row: it is the same Mac, so the live Full Control session ends.
    expect((await host.call("PUT", `/v1/permissions/${host.id}/${sameMac.id}`, { scope: "view" })).status).toBe(200);
    expect(await viewer.user!.next((f) => f.type === "session.revoked" && f.sessionId === sid)).toMatchObject({ reason: "permission_revoked" });
    expect((await ask(viewer, host, "full")).json.session.state).toBe("pending");
    expect((await ask(viewer, host, "view")).json.session.state).toBe("approved");
    await host.call("PUT", `/v1/permissions/${host.id}/${viewer.id}`, { scope: "none" });
    expect((await ask(sameMac, host, "view")).json.error.code).toBe("permission_none");
  });

  it("keeps a device's first machine: a later registration cannot move it to another Mac", async () => {
    const { account, host, viewer } = await pair();
    await alwaysAllow(host, viewer, "view");
    const other = await device(account, "Other Mac", MAC_B);
    // `other` claims MAC_A on a later registration; it stays MAC_B and keeps the default.
    other.machine = MAC_A;
    await other.register();
    expect((await ask(other, host, "full")).json.session.state).toBe("approved");
  });

  it("ends with the device: a removed identity's answer does not carry to the same Mac", async () => {
    const { account, host, viewer } = await pair();
    await alwaysAllow(host, viewer, "view");
    expect((await host.call("DELETE", `/v1/devices/${viewer.id}`)).status).toBe(200);
    const sameMac = await device(account, "Desk Mac", MAC_A);
    expect((await ask(sameMac, host, "full")).json.session.state).toBe("approved");
  });

  it("a lowered answer stays lowered when the identity it was given to is removed", async () => {
    // Review of #44039: Always for V1, None for its sibling V2, then V2 removed must not revive V1's Always.
    const { account, host, viewer } = await pair();
    await alwaysAllow(host, viewer, "full");
    const sibling = await device(account, "Desk Mac", MAC_A);
    expect((await host.call("PUT", `/v1/permissions/${host.id}/${sibling.id}`, { scope: "none" })).status).toBe(200);
    expect((await host.call("DELETE", `/v1/devices/${sibling.id}`)).status).toBe(200);
    expect((await ask(viewer, host, "full")).json.error.code).toBe("permission_none");
    await host.call("PUT", `/v1/permissions/${host.id}/${viewer.id}`, { scope: "view" });
    // With every identity that held an answer removed, the Mac is back to the account's default.
    const third = await device(account, "Desk Mac", MAC_A);
    expect((await ask(third, host, "full")).json.session.state).toBe("pending");
    expect((await host.call("DELETE", `/v1/devices/${viewer.id}`)).status).toBe(200);
    expect((await ask(third, host, "full")).json.session.state).toBe("approved");
  });

  it("refuses a machine that is not 64 lowercase hex digits", async () => {
    const account = await signIn();
    const d = await Device.create(account, "Desk Mac");
    const res = await d.call("POST", "/v1/devices", {
      id: d.id, name: d.name, platform: d.platform, signingKey: d.signingKey, agreementKey: d.agreementKey, machine: "not-a-hash",
    });
    expect(res.status).toBe(400);
  });
});
