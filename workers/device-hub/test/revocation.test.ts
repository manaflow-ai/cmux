import { describe, expect, it } from "vitest";
import { approvedSession, auditEvents, setup } from "./helpers";

async function live(ctx: Awaited<ReturnType<typeof setup>>, scope: "view" | "full" = "full") {
  const s = await approvedSession(ctx.host, ctx.viewer, scope);
  const v = (await ctx.viewer.signal(s.vt)).peer!;
  const h = (await ctx.host.signal(s.ht)).peer!;
  return { ...s, v, h };
}

describe("revocation", () => {
  it("lowering full to view revokes full sessions and closes their signaling sockets", async () => {
    const ctx = await setup();
    const s = await live(ctx, "full");
    await ctx.host.call("PUT", `/v1/permissions/${ctx.host.id}/${ctx.viewer.id}`, { scope: "view" });
    for (const d of [ctx.viewer, ctx.host]) {
      expect(await d.user!.next((f) => f.type === "session.revoked")).toEqual({ type: "session.revoked", sessionId: s.sid, reason: "permission_revoked" });
    }
    expect((await s.v.waitClosed()).code).toBe(4002);
    await s.h.waitClosed();
    expect(await auditEvents(ctx.viewer, s.sid)).toEqual(["requested", "approved", "started", "ended"]);
  });

  it("lowering to view keeps view sessions; none revokes them", async () => {
    const ctx = await setup();
    const s = await live(ctx, "view");
    await ctx.host.call("PUT", `/v1/permissions/${ctx.host.id}/${ctx.viewer.id}`, { scope: "full" });
    await ctx.host.call("PUT", `/v1/permissions/${ctx.host.id}/${ctx.viewer.id}`, { scope: "view" });
    expect(await ctx.viewer.user!.none((f) => f.type === "session.revoked")).toBe(true);
    await ctx.host.call("PUT", `/v1/permissions/${ctx.host.id}/${ctx.viewer.id}`, { scope: "none" });
    expect((await ctx.viewer.user!.next((f) => f.type === "session.revoked")).sessionId).toBe(s.sid);
    await s.h.waitClosed();
  });

  it("turning sharing off revokes the host's sessions", async () => {
    const ctx = await setup();
    const s = await live(ctx);
    await ctx.host.share(false);
    for (const d of [ctx.viewer, ctx.host]) {
      expect(await d.user!.next((f) => f.type === "session.revoked")).toMatchObject({ sessionId: s.sid, reason: "sharing_off" });
    }
    await s.v.waitClosed();
    const res = await ctx.viewer.call("POST", "/v1/sessions", { hostId: ctx.host.id, scope: "view" });
    expect(res.json.error.code).toBe("not_shared");
  });

  it("removing a device revokes its sessions on both sides", async () => {
    const ctx = await setup();
    const s = await live(ctx);
    await ctx.host.call("DELETE", `/v1/devices/${ctx.viewer.id}`);
    expect(await ctx.host.user!.next((f) => f.type === "session.revoked")).toMatchObject({ sessionId: s.sid, reason: "device_removed:viewer" });
    expect(await ctx.viewer.user!.next((f) => f.type === "session.revoked")).toMatchObject({ sessionId: s.sid, reason: "device_removed:viewer" });
    await ctx.viewer.user!.waitClosed();
    await s.h.waitClosed();
    expect(await auditEvents(ctx.host)).toContain("device_removed");
  });

  it("revokes pending requests too, without a Session DO", async () => {
    const ctx = await setup();
    const res = await ctx.viewer.call("POST", "/v1/sessions", { hostId: ctx.host.id, scope: "view" });
    await ctx.host.share(false);
    expect((await ctx.viewer.user!.next((f) => f.type === "session.revoked")).sessionId).toBe(res.json.session.id);
    const late = await ctx.host.call("POST", `/v1/sessions/${res.json.session.id}/decision`, { decision: "once" });
    expect(late.json.error.code).toBe("session_not_pending");
  });
});
