import { runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { Device, auditEvents, hubEnv, setup } from "./helpers";

// H7 walkthrough defects (2026-10-20): a View Only device could not ask for
// Full Control (D4), and removing a device left permissions naming it (D2).

describe("asking for more than the saved permission", () => {
  it("a View Only device's Full Control request goes to the host as a prompt", async () => {
    const { host, viewer } = await setup();
    await host.call("PUT", `/v1/permissions/${host.id}/${viewer.id}`, { scope: "view" });
    const res = await viewer.call("POST", "/v1/sessions", { hostId: host.id, scope: "full" });
    expect(res.status, JSON.stringify(res.json)).toBe(200);
    expect(res.json.session).toMatchObject({ state: "pending", scope: "full" });
    const sid = res.json.session.id;
    const prompt = await host.user!.next((f) => f.type === "session.request");
    expect(prompt.session).toMatchObject({ id: sid, viewerId: viewer.id, scope: "full" });
    // Allow Once grants Full Control for this session; the saved permission stays View Only.
    const once = await host.call("POST", `/v1/sessions/${sid}/decision`, { decision: "once" });
    expect(once.json.session).toMatchObject({ state: "approved", scope: "full" });
    const ticket = await viewer.user!.next((f) => f.type === "session.ticket" && f.sessionId === sid);
    expect(ticket.scope).toBe("full");
    const perms = await viewer.call("GET", `/v1/permissions?host=${host.id}`);
    expect(perms.json.permissions).toEqual([{ viewerId: viewer.id, scope: "view" }]);
    expect(await auditEvents(viewer, sid)).toEqual(["requested", "approved"]);
  });

  it("Always Allow on that prompt raises the saved permission; Deny leaves it", async () => {
    const { host, viewer } = await setup();
    await host.call("PUT", `/v1/permissions/${host.id}/${viewer.id}`, { scope: "view" });
    const denied = (await viewer.call("POST", "/v1/sessions", { hostId: host.id, scope: "full" })).json.session.id;
    await host.user!.next((f) => f.type === "session.request" && f.session.id === denied);
    await host.call("POST", `/v1/sessions/${denied}/decision`, { decision: "deny" });
    expect(await viewer.user!.next((f) => f.type === "session.denied")).toEqual({ type: "session.denied", sessionId: denied });
    expect((await viewer.call("GET", `/v1/permissions?host=${host.id}`)).json.permissions[0].scope).toBe("view");

    const asked = (await viewer.call("POST", "/v1/sessions", { hostId: host.id, scope: "full" })).json.session.id;
    await host.user!.next((f) => f.type === "session.request" && f.session.id === asked);
    const always = await host.call("POST", `/v1/sessions/${asked}/decision`, { decision: "always" });
    expect(always.json.session).toMatchObject({ state: "approved", scope: "full" });
    expect((await viewer.call("GET", `/v1/permissions?host=${host.id}`)).json.permissions[0].scope).toBe("full");
  });

  it("permission None stays a refusal with no prompt", async () => {
    const { host, viewer } = await setup();
    await host.call("PUT", `/v1/permissions/${host.id}/${viewer.id}`, { scope: "none" });
    for (const scope of ["view", "full"]) {
      const res = await viewer.call("POST", "/v1/sessions", { hostId: host.id, scope });
      expect([res.status, res.json.error.code]).toEqual([403, "permission_none"]);
    }
    expect(host.user!.frames.some((f) => f.type === "session.request")).toBe(false);
    expect((await auditEvents(host)).includes("requested")).toBe(false);
  });
});

/** Rows of the User DO's permissions table that name `id` as host or viewer. */
async function permissionRows(userId: string, id: string): Promise<number> {
  const stub = hubEnv.USER_DO.get(hubEnv.USER_DO.idFromName(userId));
  return runInDurableObject(stub, (_i, state) =>
    state.storage.sql.exec("SELECT COUNT(*) AS n FROM permissions WHERE host_id = ? OR viewer_id = ?", id, id).one().n as number,
  );
}

describe("removing a device", () => {
  it("deletes every permission that names it, as host and as viewer", async () => {
    const { account, host, viewer } = await setup();
    const third = await Device.create(account, "Mini", "macos");
    await third.register();
    await host.call("PUT", `/v1/permissions/${host.id}/${viewer.id}`, { scope: "full" });
    await host.call("PUT", `/v1/permissions/${host.id}/${third.id}`, { scope: "view" });
    await viewer.call("PUT", `/v1/permissions/${viewer.id}/${host.id}`, { scope: "view" });
    expect(await permissionRows(account.userId, viewer.id)).toBe(2);
    host.user!.frames.length = 0;

    expect((await host.call("DELETE", `/v1/devices/${viewer.id}`)).status).toBe(200);
    expect(await permissionRows(account.userId, viewer.id)).toBe(0);
    // Other devices' permissions stay.
    expect((await host.call("GET", `/v1/permissions?host=${host.id}`)).json.permissions).toEqual([{ viewerId: third.id, scope: "view" }]);
    // The hosts that listed it hear that their permissions changed.
    expect((await host.user!.next((f) => f.type === "permissions.changed" && f.hostId === host.id)).hostId).toBe(host.id);
  });
});
