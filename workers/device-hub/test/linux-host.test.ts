import { describe, expect, it } from "vitest";
import { BASE, Device, signIn, worker } from "./helpers";

/** `POST /v1/auth/device` signed by `d` for its account (no Stack token). */
async function renew(d: Device) {
  const body = JSON.stringify({ userId: d.account.userId });
  const headers = { ...(await d.headers("POST", "/v1/auth/device", body)), "content-type": "application/json" };
  const res = await worker.fetch(`${BASE}/v1/auth/device`, { method: "POST", headers, body });
  const text = await res.text();
  return { status: res.status, json: text ? (JSON.parse(text) as any) : null };
}

/** A Linux desktop host (`cmux-rd linux-host`) and a Mac viewer of the same account. */
async function linuxHost() {
  const account = await signIn();
  const linux = await Device.create(account, "Desktop", "linux");
  const mac = await Device.create(account, "Laptop", "macos");
  const reg = await linux.register();
  await mac.register();
  return { account, linux, mac, reg };
}

describe("a Linux desktop as a screen host", () => {
  it("registers as linux and lists as linux to the account's Mac", async () => {
    const { linux, mac, reg } = await linuxHost();
    expect(reg.status, JSON.stringify(reg.json)).toBe(200);
    expect(reg.json.device).toMatchObject({ id: linux.id, platform: "linux", macScreenShared: false });
    await linux.share(true);
    const listed = (await mac.call("GET", "/v1/devices")).json.devices.find((d: any) => d.id === linux.id);
    expect(listed).toMatchObject({ platform: "linux", macScreenShared: true });
  });

  it("an unknown platform is still refused", async () => {
    const account = await signIn();
    const d = await Device.create(account, "Box", "linux");
    const res = await d.call("POST", "/v1/devices", { id: d.id, name: "Box", platform: "windows-ce", signingKey: d.signingKey, agreementKey: d.agreementKey });
    expect(res.status).toBe(400);
  });

  it("is anchored and renews its own host session with its device key alone", async () => {
    const { linux } = await linuxHost();
    await linux.share(true);
    const anchor = await linux.call("POST", "/v1/auth/device/anchor", {});
    expect(anchor.status, JSON.stringify(anchor.json)).toBe(200);
    const res = await renew(linux);
    expect(res.status, JSON.stringify(res.json)).toBe(200);
    expect(res.json).toMatchObject({ scope: "host", userId: linux.account.userId });
    const host = res.json.session as string;
    const headers = { ...(await linux.headers("GET", "/v1/user/ws", "")), authorization: `Bearer ${host}`, upgrade: "websocket" };
    expect((await worker.fetch(`${BASE}/v1/user/ws`, { headers })).status).toBe(101);
  });

  it("an own Mac with no stored permission is admitted at once, with no decision on the Linux host", async () => {
    const { linux, mac } = await linuxHost();
    await linux.share(true);
    await linux.connect();
    await mac.connect();
    const res = await mac.call("POST", "/v1/sessions", { hostId: linux.id, scope: "full" });
    expect(res.json.session, JSON.stringify(res.json)).toMatchObject({ state: "approved", scope: "full" });
    const sid = res.json.session.id as string;
    expect(await linux.user!.next((f) => f.type === "session.ticket" && f.sessionId === sid)).toMatchObject({ role: "host", ownerKind: "user", peer: { id: mac.id } });
  });

  it("a permission the person stored on the Linux host wins: none refuses, view asks before Full Control", async () => {
    const { linux, mac } = await linuxHost();
    await linux.share(true);
    await linux.connect();
    await mac.connect();
    await linux.call("PUT", `/v1/permissions/${linux.id}/${mac.id}`, { scope: "none" });
    const refused = await mac.call("POST", "/v1/sessions", { hostId: linux.id, scope: "view" });
    expect([refused.status, refused.json.error.code]).toEqual([403, "permission_none"]);
    await linux.call("PUT", `/v1/permissions/${linux.id}/${mac.id}`, { scope: "view" });
    expect((await mac.call("POST", "/v1/sessions", { hostId: linux.id, scope: "view" })).json.session.state).toBe("approved");
    const full = await mac.call("POST", "/v1/sessions", { hostId: linux.id, scope: "full" });
    expect(full.json.session.state).toBe("pending");
    expect(await linux.user!.next((f) => f.type === "session.request" && f.session.id === full.json.session.id)).toMatchObject({ session: { scope: "full" } });
  });

  it("a viewer stored as ask asks first: the request waits for the Linux host's decision", async () => {
    const { linux, mac } = await linuxHost();
    await linux.share(true);
    await linux.connect();
    await mac.connect();
    await linux.call("PUT", `/v1/permissions/${linux.id}/${mac.id}`, { scope: "ask" });
    const res = await mac.call("POST", "/v1/sessions", { hostId: linux.id, scope: "view" });
    expect(res.status, JSON.stringify(res.json)).toBe(200);
    expect(res.json.session.state).toBe("pending");
    const sid = res.json.session.id as string;
    const request = await linux.user!.next((f) => f.type === "session.request" && f.session.id === sid);
    expect(request.session).toMatchObject({ viewerId: mac.id, scope: "view" });
    // No ticket before the host decides.
    expect(await mac.user!.none((f) => f.type === "session.ticket" && f.sessionId === sid)).toBe(true);
    const decided = await linux.call("POST", `/v1/sessions/${sid}/decision`, { decision: "once" });
    expect(decided.status, JSON.stringify(decided.json)).toBe(200);
    const ht = await linux.user!.next((f) => f.type === "session.ticket" && f.sessionId === sid);
    expect(ht).toMatchObject({ role: "host", scope: "view", peer: { id: mac.id } });
    expect(await mac.user!.next((f) => f.type === "session.ticket" && f.sessionId === sid)).toMatchObject({ role: "viewer" });
  });
});
