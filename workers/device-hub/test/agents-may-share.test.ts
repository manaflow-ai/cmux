import { describe, expect, it } from "vitest";
import { BASE, Device, setup, signIn, worker } from "./helpers";

/**
 * "My agents can turn screen sharing and control on my machines": one setting per account, in
 * the User DO. Off by default; only a full app session (a person's click in cmux) changes it; a
 * host session reads it; another account never sees it. Every change is audited and pushed.
 */

/** A host-scoped session for `mac` (cmux Remote with the app quit). */
async function hostSession(mac: Device): Promise<string> {
  const anchor = await mac.call("POST", "/v1/auth/device/anchor", {});
  expect(anchor.status, JSON.stringify(anchor.json)).toBe(200);
  const body = JSON.stringify({ userId: mac.account.userId });
  const headers = { ...(await mac.headers("POST", "/v1/auth/device", body)), "content-type": "application/json" };
  const res = await worker.fetch(`${BASE}/v1/auth/device`, { method: "POST", headers, body });
  const json = (await res.json()) as any;
  expect(res.status, JSON.stringify(json)).toBe(200);
  return json.session as string;
}

describe("agents may share (account setting)", () => {
  it("is off by default, and a full app session turns it on and off with an audit row and a push each time", async () => {
    const { host, viewer } = await setup();
    const first = await host.call("GET", "/v1/settings");
    expect(first.status).toBe(200);
    expect(first.json.settings).toEqual({ agentsMayShare: false, updatedAt: null, updatedBy: null });

    const on = await viewer.call("PUT", "/v1/settings", { agentsMayShare: true });
    expect(on.status, JSON.stringify(on.json)).toBe(200);
    expect(on.json.settings).toMatchObject({ agentsMayShare: true, updatedBy: viewer.id });
    await host.user!.next((f) => f.type === "settings.changed");
    // Every device of the account reads the same value.
    expect((await host.call("GET", "/v1/settings")).json.settings.agentsMayShare).toBe(true);

    // The same value again changes nothing: no second row, no push.
    await viewer.call("PUT", "/v1/settings", { agentsMayShare: true });
    expect(await host.user!.none((f) => f.type === "settings.changed")).toBe(true);

    const off = await host.call("PUT", "/v1/settings", { agentsMayShare: false });
    expect(off.json.settings).toMatchObject({ agentsMayShare: false, updatedBy: host.id });
    await viewer.user!.next((f) => f.type === "settings.changed");

    const audit = (await host.call("GET", "/v1/audit?limit=200")).json.entries as any[];
    const rows = audit.filter((e) => e.event.startsWith("agents_")).reverse();
    expect(rows.map((e) => [e.event, e.deviceId, e.deviceName])).toEqual([
      ["agents_allowed", viewer.id, "Laptop"],
      ["agents_disallowed", host.id, "Studio"],
    ]);
  });

  it("a host session reads it but never turns it on or off", async () => {
    const account = await signIn();
    const mac = await Device.create(account, "Studio", "macos");
    await mac.register();
    await mac.share(true);
    const host = await hostSession(mac);
    expect((await mac.call("GET", "/v1/settings", undefined, { session: host })).status).toBe(200);
    for (const agentsMayShare of [true, false]) {
      const res = await mac.call("PUT", "/v1/settings", { agentsMayShare }, { session: host });
      expect(res.status).toBe(403);
      expect(res.json.error.code).toBe("host_scope");
    }
    expect((await mac.call("GET", "/v1/settings")).json.settings.agentsMayShare).toBe(false);
  });

  it("belongs to one account: another account's devices neither see nor change it", async () => {
    const mine = await setup();
    const other = await setup();
    expect((await mine.host.call("PUT", "/v1/settings", { agentsMayShare: true })).status).toBe(200);
    expect((await other.host.call("GET", "/v1/settings")).json.settings.agentsMayShare).toBe(false);
    // A device of another account signing with this account's session is refused before the route.
    const crossed = await other.host.call("PUT", "/v1/settings", { agentsMayShare: false }, { session: mine.account.session });
    expect(crossed.status).not.toBe(200);
    expect((await mine.host.call("GET", "/v1/settings")).json.settings.agentsMayShare).toBe(true);
  });

  it("refuses a value that is not a boolean", async () => {
    const { host } = await setup();
    for (const body of [{}, { agentsMayShare: "yes" }, { agentsMayShare: 1 }]) {
      const res = await host.call("PUT", "/v1/settings", body);
      expect(res.status).toBe(400);
    }
    expect((await host.call("GET", "/v1/settings")).json.settings.agentsMayShare).toBe(false);
  });

  it("a sharing change an agent made names the agent session and its device in the audit row", async () => {
    const { host } = await setup({ share: false });
    const on = await host.call("PUT", `/v1/devices/${host.id}/mac-screen`, { shared: true, agent: { session: "aid-1234", device: "Studio" } });
    expect(on.status, JSON.stringify(on.json)).toBe(200);
    await host.share(false);
    const audit = (await host.call("GET", "/v1/audit?limit=200")).json.entries as any[];
    const rows = audit.filter((e) => e.event === "shared" || e.event === "unshared").reverse();
    expect(rows.map((e) => [e.event, e.detail])).toEqual([
      ["shared", "agent aid-1234 on Studio"],
      ["unshared", null],
    ]);
    const bad = await host.call("PUT", `/v1/devices/${host.id}/mac-screen`, { shared: true, agent: "aid-1234" });
    expect(bad.status).toBe(400);
  });
});
