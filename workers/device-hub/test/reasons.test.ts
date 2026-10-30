import { runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { Device, approvedSession, hubEnv, setup, signIn } from "./helpers";

async function live(ctx: Awaited<ReturnType<typeof setup>>, scope: "view" | "full" = "full") {
  const s = await approvedSession(ctx.host, ctx.viewer, scope);
  const v = (await ctx.viewer.signal(s.vt)).peer!;
  const h = (await ctx.host.signal(s.ht)).peer!;
  return { ...s, v, h };
}

const isEnd = (sid: string) => (f: any) => (f.type === "session.ended" || f.type === "session.revoked") && f.sessionId === sid;

async function endedDetail(d: Device, sid: string): Promise<string> {
  const entries = (await d.call("GET", "/v1/audit?limit=200")).json.entries as any[];
  return entries.find((e) => e.event === "ended" && e.sessionId === sid)?.detail;
}

describe("permissions are set by the host only", () => {
  it("refuses a viewer raising its own permission", async () => {
    const { host, viewer } = await setup();
    const res = await viewer.call("PUT", `/v1/permissions/${host.id}/${viewer.id}`, { scope: "full" });
    expect([res.status, res.json.error.code]).toEqual([403, "not_host"]);
    expect((await viewer.call("GET", `/v1/permissions?host=${host.id}`)).json.permissions[0].scope).toBe("ask");
    expect((await host.call("PUT", `/v1/permissions/${host.id}/${viewer.id}`, { scope: "full" })).status).toBe(200);
  });
});

describe("end reasons", () => {
  it("defaults /end to host_stopped or viewer_disconnected by side, and keeps a given reason", async () => {
    const ctx = await setup();
    const a = await approvedSession(ctx.host, ctx.viewer);
    await ctx.host.call("POST", `/v1/sessions/${a.sid}/end`, {});
    expect((await ctx.viewer.user!.next(isEnd(a.sid))).reason).toBe("host_stopped");
    const b = await approvedSession(ctx.host, ctx.viewer);
    await ctx.viewer.call("POST", `/v1/sessions/${b.sid}/end`);
    expect((await ctx.host.user!.next(isEnd(b.sid))).reason).toBe("viewer_disconnected");
    const c = await approvedSession(ctx.host, ctx.viewer);
    await ctx.viewer.call("POST", `/v1/sessions/${c.sid}/end`, { reason: "window_closed" });
    expect((await ctx.host.user!.next(isEnd(c.sid))).reason).toBe("window_closed");
  });

  it("an /end right after the client closed its signaling socket wins over the close", async () => {
    const ctx = await setup();
    const s = await live(ctx);
    s.v.ws.close(1000, "bye");
    await ctx.viewer.call("POST", `/v1/sessions/${s.sid}/end`, {});
    const msg = await ctx.host.user!.next(isEnd(s.sid));
    expect(msg.reason).toBe("viewer_disconnected");
    expect(await ctx.host.user!.none(isEnd(s.sid), 600)).toBe(true);
    expect(await endedDetail(ctx.host, s.sid)).toBe("viewer_disconnected");
  });

  it("a permission revoke right after the host closed its socket records permission_revoked", async () => {
    const ctx = await setup();
    const s = await live(ctx);
    s.h.ws.close(1000, "bye");
    await ctx.host.call("PUT", `/v1/permissions/${ctx.host.id}/${ctx.viewer.id}`, { scope: "none" });
    expect((await ctx.viewer.user!.next(isEnd(s.sid))).reason).toBe("permission_revoked");
    expect(await ctx.viewer.user!.none(isEnd(s.sid), 600)).toBe(true);
    expect(await endedDetail(ctx.viewer, s.sid)).toBe("permission_revoked");
  });

  it("a bye followed by /end records the /end reason; a bye alone ends as bye", async () => {
    const ctx = await setup();
    const s = await live(ctx);
    s.v.send({ type: "bye" });
    await ctx.viewer.call("POST", `/v1/sessions/${s.sid}/end`, {});
    expect((await ctx.host.user!.next(isEnd(s.sid))).reason).toBe("viewer_disconnected");
    expect(await ctx.host.user!.none(isEnd(s.sid), 600)).toBe(true);
    const t = await live(ctx);
    t.h.send({ type: "bye" });
    expect((await ctx.viewer.user!.next(isEnd(t.sid))).reason).toBe("bye");
  });

  it("names the removed side: device_removed:host", async () => {
    const ctx = await setup();
    const s = await live(ctx);
    await ctx.viewer.call("DELETE", `/v1/devices/${ctx.host.id}`);
    expect((await ctx.viewer.user!.next(isEnd(s.sid))).reason).toBe("device_removed:host");
    expect(await endedDetail(ctx.viewer, s.sid)).toBe("device_removed:host");
  });

  it("sharing off records sharing_off even if the host's socket closed first", async () => {
    const ctx = await setup();
    const s = await live(ctx);
    s.h.ws.close(1000, "bye");
    await ctx.host.share(false);
    expect((await ctx.viewer.user!.next(isEnd(s.sid))).reason).toBe("sharing_off");
  });
});

describe("sign-out", () => {
  it("ends the device's sessions at once with signed_out and closes its socket", async () => {
    const ctx = await setup();
    const s = await live(ctx);
    const notSelf = await ctx.host.call("POST", `/v1/devices/${ctx.viewer.id}/sign-out`);
    expect([notSelf.status, notSelf.json.error.code]).toEqual([403, "not_host"]);
    const res = await ctx.viewer.call("POST", `/v1/devices/${ctx.viewer.id}/sign-out`);
    expect(res.status).toBe(200);
    expect((await ctx.host.user!.next(isEnd(s.sid))).reason).toBe("signed_out");
    expect((await ctx.viewer.user!.waitClosed()).code).toBe(4003);
    await s.h.waitClosed();
    expect(await endedDetail(ctx.host, s.sid)).toBe("signed_out");
    await ctx.host.user!.next((f) => f.type === "devices.changed");
    // The device stays registered, offline.
    const listed = (await ctx.host.call("GET", "/v1/devices")).json.devices.find((d: any) => d.id === ctx.viewer.id);
    expect(listed.online).toBe(false);
  });
});

describe("sign-out marks the device offline at once", () => {
  it("counts a socket the server has closed as offline before the client acknowledges it", async () => {
    const ctx = await setup();
    const stub = hubEnv.USER_DO.get(hubEnv.USER_DO.idFromName(ctx.account.userId));
    // Same turn as the close: the client cannot have answered the close frame yet,
    // like an app that drops its socket without a close handshake.
    const state = await runInDurableObject(stub, (instance: any, s) => {
      for (const ws of s.getWebSockets(ctx.viewer.id)) ws.close(4003, "signed out");
      return { sockets: s.getWebSockets(ctx.viewer.id).length, online: instance.online(ctx.viewer.id) };
    });
    expect(state.online).toBe(false);
  });

  it("pushes devices.changed and lists the device offline right after sign-out", async () => {
    const ctx = await setup();
    const res = await ctx.viewer.call("POST", `/v1/devices/${ctx.viewer.id}/sign-out`);
    expect(res.status).toBe(200);
    const listed = (await ctx.host.call("GET", "/v1/devices")).json.devices.find((d: any) => d.id === ctx.viewer.id);
    expect(listed.online).toBe(false);
    await ctx.host.user!.next((f) => f.type === "devices.changed");
  });
});

describe("online state of the requesting device", () => {
  it("tells a device that connects to refetch, and lists it online", async () => {
    const account = await signIn();
    const d = await Device.create(account);
    const reg = await d.register();
    expect(reg.json.device.online).toBe(false);
    const sock = await d.connect();
    await sock.next((f) => f.type === "devices.changed");
    const me = (await d.call("GET", "/v1/devices")).json.devices.find((x: any) => x.id === d.id);
    expect(me.online).toBe(true);
  });
});
