import { describe, expect, it } from "vitest";
import { BASE, Device, signIn, worker } from "./helpers";

// The share approval carrier (cmuxterm-hq#18912 cut 2): the owner's own device sends its signed
// `cmux.share-approval.v1` for a Mac that is not sharing, and the hub pushes it to that Mac,
// which checks the signature and turns sharing on itself (acpmux share_host/approval.rs).

async function ownerAndMac() {
  const account = await signIn();
  const mac = await Device.create(account, "Studio", "macos");
  const phone = await Device.create(account, "iPhone", "ios");
  await mac.register();
  await phone.register();
  await mac.connect();
  return { account, mac, phone };
}

function approval(target: string, asker: string, confirmedBy: string, extra: Record<string, unknown> = {}) {
  return {
    v: "cmux.share-approval.v1",
    target,
    target_name: "Studio",
    asker,
    asker_name: "iPhone",
    confirmed_by: confirmedBy,
    confirmed_at: String(Math.floor(Date.now() / 1000)),
    nonce: crypto.randomUUID(),
    signature: "c2ln",
    ...extra,
  };
}

describe("POST /v1/devices/:id/share-approval", () => {
  it("carries the owner's device's approval to a Mac that is not sharing", async () => {
    const { account, mac, phone } = await ownerAndMac();
    const fields = approval(mac.id, phone.id, account.userId);
    const res = await phone.call("POST", `/v1/devices/${mac.id}/share-approval`, { approval: { ...fields, stray: "dropped" } });
    expect(res.status, JSON.stringify(res.json)).toBe(200);
    expect(res.json).toEqual({ delivered: true, hostId: mac.id });
    const push = await mac.user!.next((f) => f.type === "share.approval");
    // `from` is the hub's record of the sender; only the approval's own fields pass.
    expect(push).toEqual({ type: "share.approval", from: phone.id, approval: fields });
  });

  it("refuses a sender that is not the signing device, another account, or a device that is not a host", async () => {
    const { account, mac, phone } = await ownerAndMac();
    const laptop = await Device.create(account, "Laptop", "macos");
    await laptop.register();
    const path = `/v1/devices/${mac.id}/share-approval`;
    // Laptop forwarding the phone's approval: the hub never carries it as someone else's.
    const relayed = await laptop.call("POST", path, { approval: approval(mac.id, phone.id, account.userId) });
    expect([relayed.status, relayed.json.error.code]).toEqual([403, "not_asker"]);
    const other = await phone.call("POST", path, { approval: approval(mac.id, phone.id, "user_other") });
    expect([other.status, other.json.error.code]).toEqual([403, "other_account"]);
    const wrongPath = await phone.call("POST", `/v1/devices/${laptop.id}/share-approval`, { approval: approval(mac.id, phone.id, account.userId) });
    expect(wrongPath.status).toBe(400);
    const toPhone = await mac.call("POST", `/v1/devices/${phone.id}/share-approval`, { approval: approval(phone.id, mac.id, account.userId) });
    expect([toPhone.status, toPhone.json.error.code]).toEqual([403, "not_host"]);
    const badVersion = await phone.call("POST", path, { approval: approval(mac.id, phone.id, account.userId, { v: "x" }) });
    expect(badVersion.status).toBe(400);
    const noSig = await phone.call("POST", path, { approval: approval(mac.id, phone.id, account.userId, { signature: "" }) });
    expect(noSig.status).toBe(400);
    expect(await mac.user!.none((f) => f.type === "share.approval")).toBe(true);
  });

  it("says when the Mac is not connected", async () => {
    const account = await signIn();
    const mac = await Device.create(account, "Studio", "macos");
    const phone = await Device.create(account, "iPhone", "ios");
    await mac.register();
    await phone.register();
    const res = await phone.call("POST", `/v1/devices/${mac.id}/share-approval`, { approval: approval(mac.id, phone.id, account.userId) });
    expect([res.status, res.json.error.code]).toEqual([409, "host_offline"]);
  });

  it("never carries one from a host session (an agent's device-key renewal)", async () => {
    const { account, mac } = await ownerAndMac();
    const studio2 = await Device.create(account, "Mini", "macos");
    await studio2.register();
    await studio2.share(true);
    const anchor = await studio2.call("POST", "/v1/auth/device/anchor", {});
    expect(anchor.status, JSON.stringify(anchor.json)).toBe(200);
    const body = JSON.stringify({ userId: account.userId });
    const headers = { ...(await studio2.headers("POST", "/v1/auth/device", body)), "content-type": "application/json" };
    const renewed = await worker.fetch(`${BASE}/v1/auth/device`, { method: "POST", headers, body });
    const session = ((await renewed.json()) as { session: string }).session;
    const res = await studio2.call("POST", `/v1/devices/${mac.id}/share-approval`, { approval: approval(mac.id, studio2.id, account.userId) }, { session });
    expect([res.status, res.json.error.code]).toEqual([403, "host_scope"]);
    expect(await mac.user!.none((f) => f.type === "share.approval")).toBe(true);
  });
});

// The control approval carrier: the same checks, its own path, format and push, so the owner
// grants "control for my other signed-in machines" on a Mac from the phone.
describe("POST /v1/devices/:id/control-approval", () => {
  const control = { v: "cmux.control-approval.v1" };

  it("carries the owner's device's control approval to the Mac as its own push", async () => {
    const { account, mac, phone } = await ownerAndMac();
    const fields = approval(mac.id, phone.id, account.userId, control);
    const res = await phone.call("POST", `/v1/devices/${mac.id}/control-approval`, { approval: fields });
    expect(res.status, JSON.stringify(res.json)).toBe(200);
    expect(res.json).toEqual({ delivered: true, hostId: mac.id });
    const push = await mac.user!.next((f) => f.type === "control.approval");
    expect(push).toEqual({ type: "control.approval", from: phone.id, approval: fields });
  });

  it("carries one tap as one grant, and only from the device that signed it", async () => {
    const { account, mac, phone } = await ownerAndMac();
    const laptop = await Device.create(account, "Laptop", "macos");
    await laptop.register();
    // A share approval on the control path, and a control approval on the share path.
    const share = await phone.call("POST", `/v1/devices/${mac.id}/control-approval`, { approval: approval(mac.id, phone.id, account.userId) });
    expect(share.status).toBe(400);
    const crossed = await phone.call("POST", `/v1/devices/${mac.id}/share-approval`, { approval: approval(mac.id, phone.id, account.userId, control) });
    expect(crossed.status).toBe(400);
    const relayed = await laptop.call("POST", `/v1/devices/${mac.id}/control-approval`, { approval: approval(mac.id, phone.id, account.userId, control) });
    expect([relayed.status, relayed.json.error.code]).toEqual([403, "not_asker"]);
    const other = await phone.call("POST", `/v1/devices/${mac.id}/control-approval`, { approval: approval(mac.id, phone.id, "user_other", control) });
    expect([other.status, other.json.error.code]).toEqual([403, "other_account"]);
  });
});
