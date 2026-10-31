import { describe, expect, it } from "vitest";
import { keyFingerprint } from "../src/crypto";
import { Device, approvedSession, auditEvents, billingPlans, setup, signIn } from "./helpers";

describe("permissions", () => {
  it("defaults to ask and lists every other device", async () => {
    const { host, viewer } = await setup();
    const res = await viewer.call("GET", `/v1/permissions?host=${host.id}`);
    expect(res.json.permissions).toEqual([{ viewerId: viewer.id, scope: "ask" }]);
    const set = await host.call("PUT", `/v1/permissions/${host.id}/${viewer.id}`, { scope: "view" });
    expect(set.json.permission).toMatchObject({ hostId: host.id, viewerId: viewer.id, scope: "view" });
    expect((await host.user!.next((f) => f.type === "permissions.changed")).hostId).toBe(host.id);
    expect((await viewer.call("GET", `/v1/permissions?host=${host.id}`)).json.permissions).toEqual([{ viewerId: viewer.id, scope: "view" }]);
    expect((await host.call("PUT", `/v1/permissions/${host.id}/${viewer.id}`, { scope: "admin" })).status).toBe(400);
    expect((await host.call("PUT", `/v1/permissions/${host.id}/${host.id}`, { scope: "view" })).status).toBe(400);
  });

  it("none refuses, view asks the host for full, view and full approve at once", async () => {
    const { host, viewer } = await setup();
    const req = (scope: string) => viewer.call("POST", "/v1/sessions", { hostId: host.id, scope });
    await host.call("PUT", `/v1/permissions/${host.id}/${viewer.id}`, { scope: "none" });
    expect((await req("view")).json.error.code).toBe("permission_none");
    await host.call("PUT", `/v1/permissions/${host.id}/${viewer.id}`, { scope: "view" });
    const full = await req("full");
    expect([full.status, full.json.session.state]).toEqual([200, "pending"]);
    expect((await req("view")).json.session.state).toBe("approved");
    await host.call("PUT", `/v1/permissions/${host.id}/${viewer.id}`, { scope: "full" });
    expect((await req("full")).json.session).toMatchObject({ state: "approved", scope: "full" });
    expect((await req("view")).json.session).toMatchObject({ state: "approved", scope: "view" });
  });
});

describe("session flow", () => {
  it("approves at once with a standing permission and pushes a ticket to both devices", async () => {
    const { host, viewer } = await setup();
    const { sid, vt, ht } = await approvedSession(host, viewer, "view");
    expect(vt).toMatchObject({ role: "viewer", scope: "view", ice: [], peer: { id: host.id, name: "Studio", signingKey: host.signingKey } });
    expect(ht).toMatchObject({ role: "host", scope: "view", ice: [], peer: { id: viewer.id, name: "Laptop", signingKey: viewer.signingKey } });
    expect(vt.signalURL).toBe(`wss://hub.test/v1/sessions/${sid}/ws`);
    const payload = JSON.parse(atob(vt.ticket.split(".")[1].replace(/-/g, "+").replace(/_/g, "/")));
    expect(payload).toMatchObject({ sid, role: "viewer", dev: viewer.id, peer: host.id, peerKey: host.signingKey, scope: "view" });
    expect(payload.exp - payload.iat).toBe(60);
    expect(typeof payload.jti).toBe("string");
    expect(await auditEvents(viewer, sid)).toEqual(["requested", "approved"]);
  });

  it("asks the host when permission is ask; deny tells the viewer", async () => {
    const { host, viewer } = await setup();
    const res = await viewer.call("POST", "/v1/sessions", { hostId: host.id, scope: "full" });
    expect(res.json.session).toMatchObject({ state: "pending", scope: "full" });
    const sid = res.json.session.id;
    const req = await host.user!.next((f) => f.type === "session.request");
    expect(req.session).toEqual({ id: sid, viewerId: viewer.id, viewerName: "Laptop", viewerKeyFingerprint: await keyFingerprint(viewer.signingKey), scope: "full" });

    const notHost = await viewer.call("POST", `/v1/sessions/${sid}/decision`, { decision: "once" });
    expect([notHost.status, notHost.json.error.code]).toEqual([403, "not_host"]);

    const deny = await host.call("POST", `/v1/sessions/${sid}/decision`, { decision: "deny" });
    expect(deny.json.session.state).toBe("ended");
    expect(await viewer.user!.next((f) => f.type === "session.denied")).toEqual({ type: "session.denied", sessionId: sid });
    const again = await host.call("POST", `/v1/sessions/${sid}/decision`, { decision: "once" });
    expect([again.status, again.json.error.code]).toEqual([409, "session_not_pending"]);
    expect(await auditEvents(viewer, sid)).toEqual(["requested", "denied"]);
  });

  it("once approves without storing; the host may downgrade full to view but not upgrade", async () => {
    const { host, viewer } = await setup();
    const res = await viewer.call("POST", "/v1/sessions", { hostId: host.id, scope: "view" });
    const sid = res.json.session.id;
    expect((await host.call("POST", `/v1/sessions/${sid}/decision`, { decision: "once", scope: "full" })).status).toBe(400);
    const ok = await host.call("POST", `/v1/sessions/${sid}/decision`, { decision: "once" });
    expect(ok.json.session).toMatchObject({ state: "approved", scope: "view" });
    expect((await viewer.user!.next((f) => f.type === "session.ticket")).sessionId).toBe(sid);
    expect((await viewer.call("GET", `/v1/permissions?host=${host.id}`)).json.permissions[0].scope).toBe("ask");

    const res2 = await viewer.call("POST", "/v1/sessions", { hostId: host.id, scope: "full" });
    const down = await host.call("POST", `/v1/sessions/${res2.json.session.id}/decision`, { decision: "once", scope: "view" });
    expect(down.json.session.scope).toBe("view");
    const t = await host.user!.next((f) => f.type === "session.ticket" && f.sessionId === res2.json.session.id);
    expect(t.scope).toBe("view");
  });

  it("always stores the chosen scope so the next request is approved at once", async () => {
    const { host, viewer } = await setup();
    const res = await viewer.call("POST", "/v1/sessions", { hostId: host.id, scope: "full" });
    const sid = res.json.session.id;
    await host.call("POST", `/v1/sessions/${sid}/decision`, { decision: "always", scope: "full" });
    expect((await viewer.call("GET", `/v1/permissions?host=${host.id}`)).json.permissions[0].scope).toBe("full");
    const next = await viewer.call("POST", "/v1/sessions", { hostId: host.id, scope: "full" });
    expect(next.json.session.state).toBe("approved");
    expect(await auditEvents(viewer, sid)).toEqual(["requested", "approved"]);
    expect(await auditEvents(viewer)).toContain("permission_changed");
  });

  it("refuses an offline host (409), an unshared host (403), self and unknown hosts", async () => {
    const account = await signIn();
    const host = await Device.create(account, "Studio");
    const viewer = await Device.create(account, "Phone", "ios");
    await host.register();
    await viewer.register();
    const req = () => viewer.call("POST", "/v1/sessions", { hostId: host.id, scope: "view" });
    const notShared = await req();
    expect([notShared.status, notShared.json.error.code]).toEqual([403, "not_shared"]);
    await host.share(true);
    const offline = await req();
    expect([offline.status, offline.json.error.code]).toEqual([409, "host_offline"]);
    expect((await viewer.call("POST", "/v1/sessions", { hostId: viewer.id, scope: "view" })).status).toBe(400);
    expect((await viewer.call("POST", "/v1/sessions", { hostId: crypto.randomUUID(), scope: "view" })).status).toBe(404);
    expect((await viewer.call("POST", "/v1/sessions", { hostId: host.id, scope: "admin" })).status).toBe(400);
  });

  it("mints cmux relay ICE only for paid users, and only while the session is active", async () => {
    const free = await setup();
    const f = await approvedSession(free.host, free.viewer);
    expect(f.vt.ice).toEqual([]);
    expect((await free.viewer.call("POST", `/v1/sessions/${f.sid}/ice`)).json).toEqual({ ice: [] });

    const paidSub = `pro-${crypto.randomUUID()}`;
    billingPlans.set(paidSub, { subscriptionPlanId: "pro" });
    const paid = await setup({ userId: paidSub });
    const p = await approvedSession(paid.host, paid.viewer);
    expect(p.vt.ice).toEqual([
      { urls: ["stun:stun.cloudflare.com:3478"] },
      { urls: ["turn:turn.cloudflare.com:3478?transport=udp", "turns:turn.cloudflare.com:443?transport=tcp"], username: "u1", credential: "c1" },
    ]);
    expect(p.ht.ice).toEqual(p.vt.ice);
    const ice = await paid.viewer.call("POST", `/v1/sessions/${p.sid}/ice`);
    expect(ice.json.ice).toHaveLength(2);
    await paid.viewer.call("POST", `/v1/sessions/${p.sid}/end`, { reason: "done" });
    const after = await paid.viewer.call("POST", `/v1/sessions/${p.sid}/ice`);
    expect([after.status, after.json.error.code]).toEqual([409, "session_not_active"]);
  });

  it("ends from either side with session.revoked to both", async () => {
    const { host, viewer } = await setup();
    const { sid } = await approvedSession(host, viewer);
    expect((await host.call("POST", `/v1/sessions/${sid}/end`, { reason: "user" })).status).toBe(200);
    expect(await viewer.user!.next((f) => f.type === "session.revoked")).toEqual({ type: "session.revoked", sessionId: sid, reason: "user" });
    expect(await host.user!.next((f) => f.type === "session.revoked")).toEqual({ type: "session.revoked", sessionId: sid, reason: "user" });
    const other = await signIn();
    const stranger = await Device.create(other);
    await stranger.register();
    expect((await stranger.call("POST", `/v1/sessions/${sid}/end`, {})).status).toBe(404);
  });
});
