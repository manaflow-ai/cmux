import { runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { Device, approvedSession, auditEvents, hubEnv, setup, signIn } from "./helpers";

const userStub = (userId: string) => hubEnv.USER_DO.get(hubEnv.USER_DO.idFromName(userId));

/** Moves every pending offline mark 31 s into the past, then runs the alarm. */
async function expireGrace(userId: string) {
  const stub = userStub(userId);
  await runInDurableObject(stub, (_i, s) => {
    s.storage.sql.exec("UPDATE offline SET since = since - 31000");
  });
  return runDurableObjectAlarm(stub);
}

describe("re-registration keeps a user-set name", () => {
  it("first registration sets the name; after a rename, registration does not overwrite it", async () => {
    const account = await signIn();
    const d = await Device.create(account, "MacBook Pro");
    await d.register();
    const other = await Device.create(account, "Phone", "ios");
    await other.register();
    // Without a rename, registration still updates the name.
    (d as any).name = "MacBook Pro (2)";
    expect((await d.register()).json.device.name).toBe("MacBook Pro (2)");
    await other.call("PATCH", `/v1/devices/${d.id}`, { name: "Desk Mac" });
    (d as any).name = "MacBook Pro";
    expect((await d.register()).json.device.name).toBe("Desk Mac");
    const list = await other.call("GET", "/v1/devices");
    expect(list.json.devices.find((x: any) => x.id === d.id).name).toBe("Desk Mac");
  });
});

describe("devices that go offline", () => {
  it("ends the device's sessions with peer_offline once the grace period passes", async () => {
    const { account, host, viewer } = await setup();
    const s = await approvedSession(host, viewer);
    const v = (await viewer.signal(s.vt)).peer!;
    const h = (await host.signal(s.ht)).peer!;
    // Full Control is above View Only, so this request waits for the host.
    const pending = await viewer.call("POST", "/v1/sessions", { hostId: host.id, scope: "full" });
    expect(pending.json.session.state).toBe("pending");

    viewer.user!.ws.close(1000, "crash");
    await viewer.user!.waitClosed();
    // Within the grace period nothing ends.
    expect(await host.user!.none((f) => f.type === "session.ended")).toBe(true);
    expect(await expireGrace(account.userId)).toBe(true);
    const ended = [await host.user!.next((f) => f.type === "session.ended"), await host.user!.next((f) => f.type === "session.ended")];
    expect(ended.map((e) => e.sessionId).sort()).toEqual([s.sid, pending.json.session.id].sort());
    expect(ended.every((e) => e.reason === "peer_offline")).toBe(true);
    await h.waitClosed();
    await v.waitClosed();
    const entries = (await host.call("GET", "/v1/audit?limit=200")).json.entries as any[];
    expect(entries.find((e) => e.event === "ended" && e.sessionId === s.sid).detail).toBe("peer_offline");
  });

  it("keeps sessions when the device reconnects within the grace period", async () => {
    const { account, host, viewer } = await setup();
    const s = await approvedSession(host, viewer);
    viewer.user!.ws.close(1000, "network");
    await viewer.user!.waitClosed();
    await viewer.connect();
    await expireGrace(account.userId);
    expect(await host.user!.none((f) => f.type === "session.ended")).toBe(true);
    expect(await auditEvents(viewer, s.sid)).toEqual(["requested", "approved"]);
  });

  it("does not treat a replaced socket as offline", async () => {
    const { account, host, viewer } = await setup();
    await approvedSession(host, viewer);
    const old = viewer.user!;
    await viewer.connect();
    await old.waitClosed();
    await expireGrace(account.userId);
    expect(await host.user!.none((f) => f.type === "session.ended")).toBe(true);
  });
});

describe("audit per device", () => {
  it("filters entries to those naming the device as viewer or host", async () => {
    const { host, viewer } = await setup();
    const third = await Device.create(host.account, "Phone", "ios");
    await third.register();
    await approvedSession(host, viewer);
    const all = (await viewer.call("GET", "/v1/audit?limit=200")).json.entries as any[];
    const mine = (await third.call("GET", `/v1/audit?limit=200&device=${third.id}`)).json.entries as any[];
    // Only device events, which every device's History shows: no session or permission names it.
    expect(new Set(mine.map((e) => e.event))).toEqual(new Set(["device_added"]));
    expect(mine).toHaveLength(3);
    const hostOnly = (await viewer.call("GET", `/v1/audit?limit=200&device=${host.id}`)).json.entries as any[];
    expect(hostOnly.length).toBeGreaterThan(0);
    expect(hostOnly.every((e) => e.hostId === host.id || e.viewerId === host.id || e.event === "device_added")).toBe(true);
    expect(mine.length).toBeLessThan(all.length);
  });
});
