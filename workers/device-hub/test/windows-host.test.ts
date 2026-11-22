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

/** A Windows PC (`cmux-rd windows-host`) and a Mac of the same account. */
async function windowsPC() {
  const account = await signIn();
  const pc = await Device.create(account, "DESKTOP-1", "windows");
  const mac = await Device.create(account, "Laptop", "macos");
  const reg = await pc.register();
  await mac.register();
  return { account, pc, mac, reg };
}

describe("a Windows PC on the account", () => {
  it("registers as windows and lists as windows to the account's Mac", async () => {
    const { pc, mac, reg } = await windowsPC();
    expect(reg.status, JSON.stringify(reg.json)).toBe(200);
    expect(reg.json.device).toMatchObject({ id: pc.id, platform: "windows", macScreenShared: false });
    const listed = (await mac.call("GET", "/v1/devices")).json.devices.find((d: any) => d.id === pc.id);
    expect(listed).toMatchObject({ platform: "windows", macScreenShared: false });
  });

  it("is anchored and renews its own host session, so it stays online without a token", async () => {
    const { pc } = await windowsPC();
    const anchor = await pc.call("POST", "/v1/auth/device/anchor", {});
    expect(anchor.status, JSON.stringify(anchor.json)).toBe(200);
    const res = await renew(pc);
    expect(res.status, JSON.stringify(res.json)).toBe(200);
    expect(res.json).toMatchObject({ scope: "host", userId: pc.account.userId });
    const headers = { ...(await pc.headers("GET", "/v1/user/ws", "")), authorization: `Bearer ${res.json.session}`, upgrade: "websocket" };
    expect((await worker.fetch(`${BASE}/v1/user/ws`, { headers })).status).toBe(101);
  });

  it("a PC that does not share its screen is not viewed: the session is refused", async () => {
    const { pc, mac } = await windowsPC();
    await pc.connect();
    await mac.connect();
    const res = await mac.call("POST", "/v1/sessions", { hostId: pc.id, scope: "view" });
    expect(res.status, JSON.stringify(res.json)).toBe(403);
    expect(res.json.error.code).toBe("not_shared");
  });
});
