import { describe, expect, it } from "vitest";
import { Device, setup, signIn } from "./helpers";

// Leo, 2026-11-16 (ask-da398bba67): "if you have indeed connected a machine, you should be able to
// just screen share onto it freely. Like you shouldn't need permissions on it". Every device in a
// UserDO is signed in to that one account, so a device with no stored permission reaches the host
// with Full Control and no prompt there. What the person stored, and every device the hub did not
// authenticate for this account, still gets the prompt or the refusal.

describe("the person's own devices", () => {
  it("an own device with no stored permission is admitted with Full Control: no prompt on the host", async () => {
    const { host, viewer } = await setup();
    expect((await viewer.call("GET", `/v1/permissions?host=${host.id}`)).json.permissions).toEqual([{ viewerId: viewer.id, scope: "full" }]);
    const res = await viewer.call("POST", "/v1/sessions", { hostId: host.id, scope: "full" });
    expect(res.status, JSON.stringify(res.json)).toBe(200);
    expect(res.json.session).toMatchObject({ state: "approved", scope: "full", hubApproval: "permission" });
    const sid = res.json.session.id as string;
    const ht = await host.user!.next((f) => f.type === "session.ticket" && f.sessionId === sid);
    // The host decides "own" from this, which the hub writes, never from the viewer.
    expect(ht).toMatchObject({ role: "host", scope: "full", ownerKind: "user", peer: { id: viewer.id } });
    expect(await viewer.user!.next((f) => f.type === "session.ticket" && f.sessionId === sid)).toMatchObject({ ownerKind: "user" });
    expect(await host.user!.none((f) => f.type === "session.request")).toBe(true);
  });

  it("still asks: a permission the person stored as ask wins over the default", async () => {
    const { host, viewer } = await setup();
    await host.call("PUT", `/v1/permissions/${host.id}/${viewer.id}`, { scope: "ask" });
    const res = await viewer.call("POST", "/v1/sessions", { hostId: host.id, scope: "view" });
    expect(res.json.session).toMatchObject({ state: "pending", hubApproval: "requested" });
    const req = await host.user!.next((f) => f.type === "session.request");
    expect(req.session).toMatchObject({ id: res.json.session.id, viewerId: viewer.id });
  });

  it("still refuses: none or view the person stored wins (view asks for Full Control)", async () => {
    const { host, viewer } = await setup();
    await host.call("PUT", `/v1/permissions/${host.id}/${viewer.id}`, { scope: "none" });
    expect((await viewer.call("POST", "/v1/sessions", { hostId: host.id, scope: "view" })).json.error.code).toBe("permission_none");
    await host.call("PUT", `/v1/permissions/${host.id}/${viewer.id}`, { scope: "view" });
    expect((await viewer.call("POST", "/v1/sessions", { hostId: host.id, scope: "full" })).json.session.state).toBe("pending");
  });

  it("still refuses: a device of another account never reaches this host", async () => {
    const { host } = await setup();
    const other = await signIn();
    const stranger = await Device.create(other, "Stranger", "macos");
    await stranger.register();
    await stranger.connect();
    const res = await stranger.call("POST", "/v1/sessions", { hostId: host.id, scope: "view" });
    expect([res.status, res.json.error.code]).toEqual([404, "not_found"]);
    expect((await stranger.call("GET", "/v1/devices")).json.devices.map((d: any) => d.id)).not.toContain(host.id);
    expect(await host.user!.none((f) => f.type === "session.request" || f.type === "session.ticket")).toBe(true);
  });

  it("a pending request reaches the host again when its socket comes back", async () => {
    const { host, viewer } = await setup();
    await host.call("PUT", `/v1/permissions/${host.id}/${viewer.id}`, { scope: "ask" });
    const res = await viewer.call("POST", "/v1/sessions", { hostId: host.id, scope: "view" });
    expect(res.json.session.state).toBe("pending");
    const sid = res.json.session.id as string;
    // The host's first socket drops before it shows the prompt; the one it opens next must get it.
    const again = await host.connect();
    const req = await again.next((f) => f.type === "session.request" && f.session?.id === sid);
    expect(req.session).toMatchObject({ id: sid, viewerId: viewer.id, scope: "view" });
  });

  it("admission follows membership: a removed device loses its open session and the next one", async () => {
    const { host, viewer } = await setup();
    const res = await viewer.call("POST", "/v1/sessions", { hostId: host.id, scope: "full" });
    const sid = res.json.session.id as string;
    await host.user!.next((f) => f.type === "session.ticket" && f.sessionId === sid);
    expect((await host.call("DELETE", `/v1/devices/${viewer.id}`)).status).toBe(200);
    expect(await host.user!.next((f) => f.type === "session.revoked")).toMatchObject({ sessionId: sid, reason: "device_removed:viewer" });
    const again = await viewer.call("POST", "/v1/sessions", { hostId: host.id, scope: "view" });
    expect(again.status).not.toBe(200);
    expect(await host.user!.none((f) => f.type === "session.ticket" && f.sessionId !== sid)).toBe(true);
  });
});
