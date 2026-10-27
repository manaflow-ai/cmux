import { describe, expect, it } from "vitest";
import { Device, auditEvents, billingPlans, signIn } from "./helpers";

describe("device registration and signed requests", () => {
  it("registers a device signed by its own key and serves /v1/me", async () => {
    const account = await signIn();
    const d = await Device.create(account, "Studio", "macos");
    const reg = await d.register();
    expect(reg.json.device).toMatchObject({ id: d.id, name: "Studio", platform: "macos", signingKey: d.signingKey, agreementKey: d.agreementKey, macScreenShared: false, online: false });
    const me = await d.call("GET", "/v1/me");
    expect(me.status).toBe(200);
    expect(me.json).toMatchObject({ userId: account.userId, plan: "free", device: { id: d.id } });
    // Re-registering updates the name and keeps the key.
    const again = await Device.create(account);
    Object.assign(again, { id: d.id, signing: d.signing, signingKey: d.signingKey });
    (again as any).name = "Renamed";
    expect((await again.register()).json.device.name).toBe("Renamed");
    expect(await auditEvents(d)).toEqual(["device_added"]);
  });

  it("reports the plan from the caller's cmux subscription", async () => {
    const sub = `pro-${crypto.randomUUID()}`;
    billingPlans.set(sub, { subscriptionPlanId: "pro" });
    const account = await signIn(sub);
    const d = await Device.create(account);
    await d.register();
    expect((await d.call("GET", "/v1/me")).json.plan).toBe("paid");
    billingPlans.set(sub, { subscriptionPlanId: "go" });
    expect((await d.call("GET", "/v1/me")).json.plan).toBe("free");
    billingPlans.set(sub, { status: 500 });
    expect((await d.call("GET", "/v1/me")).json.plan).toBe("free");
  });

  it("rejects registration signed by another key or for a mismatched id", async () => {
    const account = await signIn();
    const d = await Device.create(account);
    const other = await Device.create(account);
    const body = { id: d.id, name: "x", platform: "macos", signingKey: d.signingKey, agreementKey: d.agreementKey };
    const res = await d.call("POST", "/v1/devices", body, { key: other.signing.privateKey });
    expect(res.status).toBe(401);
    expect(res.json.error.code).toBe("bad_signature");
    const mismatched = await d.call("POST", "/v1/devices", { ...body, id: other.id });
    expect(mismatched.status).toBe(400);
    const badKey = await d.call("POST", "/v1/devices", { ...body, signingKey: btoa("short") });
    expect(badKey.status).toBe(400);
  });

  it("refuses to replace a registered device's signing key", async () => {
    const account = await signIn();
    const d = await Device.create(account);
    await d.register();
    const thief = await Device.create(account);
    thief.id = d.id;
    const res = await thief.call("POST", "/v1/devices", { id: d.id, name: "evil", platform: "macos", signingKey: thief.signingKey, agreementKey: thief.agreementKey });
    expect(res.status).toBe(409);
    expect(res.json.error.code).toBe("device_key_mismatch");
  });

  it("rejects bad signatures, stale timestamps, replays and unknown devices", async () => {
    const account = await signIn();
    const d = await Device.create(account);
    await d.register();
    const other = await Device.create(account);

    const bad = await d.call("GET", "/v1/devices", undefined, { key: other.signing.privateKey });
    expect([bad.status, bad.json.error.code]).toEqual([401, "bad_signature"]);

    const stale = await d.call("GET", "/v1/devices", undefined, { ts: Math.floor(Date.now() / 1000) - 61 });
    expect([stale.status, stale.json.error.code]).toEqual([401, "stale_timestamp"]);
    const future = await d.call("GET", "/v1/devices", undefined, { ts: Math.floor(Date.now() / 1000) + 61 });
    expect(future.json.error.code).toBe("stale_timestamp");

    const ok = await d.call("GET", "/v1/devices");
    expect(ok.status).toBe(200);
    const replay = await d.call("GET", "/v1/devices", undefined, { headers: { ...ok.headers } });
    expect([replay.status, replay.json.error.code]).toEqual([401, "replay"]);

    // The signature covers the path and the body.
    const signedForMe = await d.headers("GET", "/v1/me", "");
    const moved = await d.call("GET", "/v1/devices", undefined, { headers: { ...signedForMe } });
    expect(moved.json.error.code).toBe("bad_signature");
    const h = await d.headers("PATCH", `/v1/devices/${d.id}`, JSON.stringify({ name: "a" }));
    const tampered = await d.call("PATCH", `/v1/devices/${d.id}`, { name: "b" }, { headers: { ...h } });
    expect(tampered.json.error.code).toBe("bad_signature");

    const unknown = await other.call("GET", "/v1/devices");
    expect([unknown.status, unknown.json.error.code]).toEqual([401, "bad_signature"]);
    const missing = await d.call("GET", "/v1/devices", undefined, { headers: {} });
    expect(missing.json.error.code).toBe("bad_signature");
  });

  it("keeps devices per user: another account cannot see or sign as them", async () => {
    const a = await signIn();
    const b = await signIn();
    const da = await Device.create(a);
    await da.register();
    const asB = await da.call("GET", "/v1/devices", undefined, { session: b.session });
    expect(asB.json.error.code).toBe("bad_signature");
  });

  it("lists devices with online state, renames and removes them", async () => {
    const account = await signIn();
    const mac = await Device.create(account, "Studio");
    const phone = await Device.create(account, "Phone", "ios");
    await mac.register();
    await phone.register();
    await mac.connect();
    const list = await phone.call("GET", "/v1/devices");
    expect(list.json.devices.map((x: any) => [x.name, x.online])).toEqual([
      ["Studio", true],
      ["Phone", false],
    ]);
    const renamed = await phone.call("PATCH", `/v1/devices/${mac.id}`, { name: "Desk" });
    expect(renamed.json.device.name).toBe("Desk");
    await mac.user!.next((f) => f.type === "devices.changed");

    expect((await phone.call("DELETE", `/v1/devices/${mac.id}`)).status).toBe(200);
    expect((await mac.user!.waitClosed()).code).toBe(4001);
    expect((await phone.call("GET", "/v1/devices")).json.devices.map((x: any) => x.id)).toEqual([phone.id]);
    const gone = await mac.call("GET", "/v1/me");
    expect([gone.status, gone.json.error.code]).toEqual([403, "device_removed"]);
    // A removed id cannot be registered again.
    const back = await mac.call("POST", "/v1/devices", { id: mac.id, name: "x", platform: "macos", signingKey: mac.signingKey, agreementKey: mac.agreementKey });
    expect(back.json.error.code).toBe("device_removed");
    expect((await phone.call("DELETE", `/v1/devices/${mac.id}`)).status).toBe(404);
  });

  it("lets only the device itself change its Mac Screen sharing", async () => {
    const account = await signIn();
    const mac = await Device.create(account);
    const phone = await Device.create(account, "Phone", "ios");
    await mac.register();
    await phone.register();
    const res = await phone.call("PUT", `/v1/devices/${mac.id}/mac-screen`, { shared: true });
    expect([res.status, res.json.error.code]).toEqual([403, "not_host"]);
    const ok = await mac.call("PUT", `/v1/devices/${mac.id}/mac-screen`, { shared: true });
    expect(ok.json.device.macScreenShared).toBe(true);
    await mac.call("PUT", `/v1/devices/${mac.id}/mac-screen`, { shared: false });
    expect(await auditEvents(mac)).toEqual(["device_added", "device_added", "shared", "unshared"]);
  });
});
