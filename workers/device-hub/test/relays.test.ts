import { describe, expect, it } from "vitest";
import { Device, auditEvents, setup } from "./helpers";

describe("relays", () => {
  it("stores sealed blobs as given and returns each device only its own", async () => {
    const { host, viewer } = await setup();
    const third = await Device.create(host.account, "Phone", "ios");
    await third.register();
    const relay = {
      name: "Home TURN",
      urls: ["turn:turn.example:3478", "turns:turn.example:5349"],
      authMode: "shared_secret",
      sealed: { [host.id]: btoa("sealed-for-host"), [viewer.id]: btoa("sealed-for-viewer") },
      enabled: true,
      priority: 10,
    };
    const put = await host.call("PUT", "/v1/relays/home", relay);
    expect(put.status).toBe(200);
    expect(put.json.relay).toMatchObject({ id: "home", ownerKind: "user", ownerId: host.account.userId, name: "Home TURN", sealed: { [host.id]: btoa("sealed-for-host") } });
    await viewer.user!.next((f) => f.type === "relays.changed");

    const v = await viewer.call("GET", "/v1/relays");
    expect(v.json.relays).toHaveLength(1);
    expect(v.json.relays[0].sealed).toEqual({ [viewer.id]: btoa("sealed-for-viewer") });
    expect(v.json.relays[0]).toMatchObject({ urls: relay.urls, authMode: "shared_secret", enabled: true, priority: 10 });
    expect((await third.call("GET", "/v1/relays")).json.relays[0].sealed).toEqual({});

    const upd = await viewer.call("PUT", "/v1/relays/home", { ...relay, enabled: false, sealed: { [third.id]: btoa("x") } });
    expect(upd.json.relay.enabled).toBe(false);
    expect((await third.call("GET", "/v1/relays")).json.relays[0].sealed).toEqual({ [third.id]: btoa("x") });
    expect((await host.call("GET", "/v1/relays")).json.relays[0].sealed).toEqual({});

    expect((await host.call("PUT", "/v1/relays/bad", { ...relay, urls: ["http://x"] })).status).toBe(400);
    expect((await host.call("PUT", "/v1/relays/bad", { ...relay, authMode: "oauth" })).status).toBe(400);
    expect((await host.call("PUT", "/v1/relays/bad", { ...relay, sealed: { notadevice: "x" } })).status).toBe(400);
    expect((await host.call("PUT", "/v1/relays/b%20d", relay)).status).toBe(400);

    expect((await host.call("DELETE", "/v1/relays/home")).status).toBe(200);
    expect((await host.call("GET", "/v1/relays")).json.relays).toEqual([]);
    expect((await host.call("DELETE", "/v1/relays/home")).status).toBe(404);
    // Relay changes are not audit events (the list is fixed by the protocol).
    expect(await auditEvents(host)).not.toContain("relay_changed");
  });
});
