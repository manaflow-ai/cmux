import { runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { approvedSession, hubEnv, setup, waitFor } from "./helpers";

describe("audit", () => {
  it("records every event kind, newest first, with paging", async () => {
    const { host, viewer } = await setup();
    // requested + denied
    const r = await viewer.call("POST", "/v1/sessions", { hostId: host.id, scope: "view" });
    await host.call("POST", `/v1/sessions/${r.json.session.id}/decision`, { decision: "deny" });
    // permission_changed, approved, started, ended
    const s = await approvedSession(host, viewer);
    const v = (await viewer.signal(s.vt)).peer!;
    const h = (await host.signal(s.ht)).peer!;
    v.send({ type: "bye" });
    await h.waitClosed();
    // unshared, device_removed
    await host.share(false);
    await host.call("DELETE", `/v1/devices/${viewer.id}`);

    const res = await waitFor(() => host.call("GET", "/v1/audit?limit=200"), (x) => x.json.entries.some((e: any) => e.event === "ended"));
    const events = new Set((res.json.entries as any[]).map((e) => e.event));
    for (const e of ["shared", "unshared", "requested", "approved", "denied", "started", "ended", "permission_changed", "device_added", "device_removed"]) {
      expect(events, e).toContain(e);
    }
    const ts = (res.json.entries as any[]).map((e) => e.ts);
    expect([...ts].sort((a, b) => b - a)).toEqual(ts);

    const page = await host.call("GET", "/v1/audit?limit=2");
    expect(page.json.entries).toHaveLength(2);
    const older = await host.call("GET", `/v1/audit?before=${page.json.entries[1].ts}`);
    expect(older.json.entries.every((e: any) => e.ts < page.json.entries[1].ts)).toBe(true);
  });

  it("stores metadata only: no SDP or candidates reach the audit table", async () => {
    const { account, host, viewer } = await setup();
    const s = await approvedSession(host, viewer);
    const v = (await viewer.signal(s.vt)).peer!;
    const h = (await host.signal(s.ht)).peer!;
    v.send({ type: "offer", sdp: "SECRET-SDP", fpSig: "x" });
    await h.next((f) => f.type === "offer");
    v.send({ type: "bye" });
    await h.waitClosed();
    await waitFor(() => host.call("GET", "/v1/audit"), (x) => x.json.entries.some((e: any) => e.event === "ended"));
    const stub = hubEnv.USER_DO.get(hubEnv.USER_DO.idFromName(account.userId));
    const dump = await runInDurableObject(stub, (_i, state) => JSON.stringify(state.storage.sql.exec("SELECT * FROM audit").toArray()));
    expect(dump).not.toContain("SECRET-SDP");
  });
});
