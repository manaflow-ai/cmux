import { runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { approvedSession, BASE, hubEnv, setup } from "./helpers";

// PR #22788 review: a Durable Object serves other requests while it awaits a
// fetch, so a session can end (sharing off, removal, access lowered) while
// approve() waits on the Session DO. Nothing may start it after that.

describe("a session that ends while it is being approved", () => {
  it("approve() on a session that already ended sends no ticket and leaves it ended", async () => {
    const { account, host, viewer } = await setup();
    await host.call("PUT", `/v1/permissions/${host.id}/${viewer.id}`, { scope: "view" });
    const sid = (await viewer.call("POST", "/v1/sessions", { hostId: host.id, scope: "full" })).json.session.id as string;
    await host.user!.next((f) => f.type === "session.request" && f.session.id === sid);
    await host.share(false);
    await viewer.user!.next((f) => f.type === "session.revoked" && f.sessionId === sid);

    // The approval that was in flight resumes now.
    const stub = hubEnv.USER_DO.get(hubEnv.USER_DO.idFromName(account.userId));
    const state = await runInDurableObject(stub, async (instance: any, ctx) => {
      const row = ctx.storage.sql.exec("SELECT * FROM sessions WHERE id = ?", sid).one();
      await instance.approve({ ...row, scope: "full" }, { userId: account.userId, origin: BASE });
      return ctx.storage.sql.exec("SELECT state FROM sessions WHERE id = ?", sid).one().state;
    });
    expect(state).toBe("ended");
    expect(await viewer.user!.none((f) => f.type === "session.ticket" && f.sessionId === sid)).toBe(true);
    expect(await host.user!.none((f) => f.type === "session.ticket" && f.sessionId === sid)).toBe(true);
  });

  it("a session that ends while approve() waits on the Session DO gets no ticket", async () => {
    const { account, host, viewer } = await setup();
    await host.call("PUT", `/v1/permissions/${host.id}/${viewer.id}`, { scope: "view" });
    const sid = (await viewer.call("POST", "/v1/sessions", { hostId: host.id, scope: "full" })).json.session.id as string;
    await host.user!.next((f) => f.type === "session.request" && f.session.id === sid);

    const stub = hubEnv.USER_DO.get(hubEnv.USER_DO.idFromName(account.userId));
    const state = await runInDurableObject(stub, async (instance: any, ctx) => {
      const real = instance.env;
      // The session ends (sharing off) while the Session DO init is in flight.
      const sessions = {
        idFromName: (name: string) => real.SESSION_DO.idFromName(name),
        get: (id: DurableObjectId) => {
          const target = real.SESSION_DO.get(id);
          return {
            fetch: async (url: string, init?: RequestInit) => {
              const res = await target.fetch(url, init);
              if (url.endsWith("/internal/init")) {
                const row = ctx.storage.sql.exec("SELECT * FROM sessions WHERE id = ?", sid).one();
                await instance.endSession(row, "sharing_off", "revoked", true);
              }
              return res;
            },
          };
        },
      };
      instance.env = { ...real, SESSION_DO: sessions };
      try {
        ctx.storage.sql.exec("UPDATE sessions SET state = 'approved' WHERE id = ?", sid);
        const row = ctx.storage.sql.exec("SELECT * FROM sessions WHERE id = ?", sid).one();
        await instance.approve(row, { userId: account.userId, origin: BASE });
      } finally {
        instance.env = real;
      }
      return ctx.storage.sql.exec("SELECT state FROM sessions WHERE id = ?", sid).one().state;
    });
    expect(state).toBe("ended");
    expect(await viewer.user!.next((f) => f.type === "session.revoked" && f.sessionId === sid)).toMatchObject({ reason: "sharing_off" });
    expect(await viewer.user!.none((f) => f.type === "session.ticket" && f.sessionId === sid)).toBe(true);
    expect(await host.user!.none((f) => f.type === "session.ticket" && f.sessionId === sid)).toBe(true);
  });

  it("a Session DO that was closed refuses a later init (the close can arrive first)", async () => {
    const stub = hubEnv.SESSION_DO.get(hubEnv.SESSION_DO.idFromName(crypto.randomUUID()));
    expect((await stub.fetch("https://session.do/internal/close", { method: "POST", body: JSON.stringify({ reason: "sharing_off" }) })).status).toBe(200);
    const init = await stub.fetch("https://session.do/internal/init", {
      method: "POST",
      body: JSON.stringify({ sid: "s", userId: "u", scope: "full", viewer: { id: "v", key: "k" }, host: { id: "h", key: "k" } }),
    });
    expect(init.status).toBe(409);
  });
});

describe("lowering Full Control to Ask", () => {
  it("ends the live Full Control session", async () => {
    const ctx = await setup();
    const s = await approvedSession(ctx.host, ctx.viewer, "full");
    await ctx.host.call("PUT", `/v1/permissions/${ctx.host.id}/${ctx.viewer.id}`, { scope: "ask" });
    expect(await ctx.viewer.user!.next((f) => f.type === "session.revoked")).toMatchObject({ sessionId: s.sid, reason: "permission_revoked" });
  });

  it("keeps a pending request: under Ask it still waits for the host", async () => {
    const { host, viewer } = await setup();
    await host.call("PUT", `/v1/permissions/${host.id}/${viewer.id}`, { scope: "view" });
    const sid = (await viewer.call("POST", "/v1/sessions", { hostId: host.id, scope: "full" })).json.session.id as string;
    await host.user!.next((f) => f.type === "session.request" && f.session.id === sid);
    await host.call("PUT", `/v1/permissions/${host.id}/${viewer.id}`, { scope: "ask" });
    expect(await viewer.user!.none((f) => f.type === "session.revoked" && f.sessionId === sid)).toBe(true);
    const once = await host.call("POST", `/v1/sessions/${sid}/decision`, { decision: "once" });
    expect(once.json.session).toMatchObject({ state: "approved", scope: "full" });
  });
});
