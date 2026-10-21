import { describe, expect, it } from "vitest";
import { approvedSession, setup } from "./helpers";

async function history(d: any, device: string) {
  const res = await d.call("GET", `/v1/audit?limit=200&device=${device}`);
  expect(res.status).toBe(200);
  return res.json.entries as any[];
}

describe("removing a device keeps History", () => {
  for (const removedRole of ["viewer", "host"] as const) {
    it(`removing the ${removedRole} keeps every prior row in the other device's History, with names`, async () => {
      const ctx = await setup();
      for (let i = 0; i < 3; i++) {
        const s = await approvedSession(ctx.host, ctx.viewer);
        const v = (await ctx.viewer.signal(s.vt)).peer!;
        const h = (await ctx.host.signal(s.ht)).peer!;
        await ctx.viewer.call("POST", `/v1/sessions/${s.sid}/end`, {});
        await v.waitClosed();
        await h.waitClosed();
      }
      const live = await approvedSession(ctx.host, ctx.viewer);
      const removed = removedRole === "viewer" ? ctx.viewer : ctx.host;
      const remaining = removedRole === "viewer" ? ctx.host : ctx.viewer;
      const before = await history(remaining, remaining.id);
      expect((await remaining.call("DELETE", `/v1/devices/${removed.id}`)).status).toBe(200);
      const after = await history(remaining, remaining.id);
      // Every row from before is still there, plus the live session's end and the removal.
      expect(after.map((e) => e.id)).toEqual(expect.arrayContaining(before.map((e) => e.id)));
      expect(after.length).toBe(before.length + 2);
      const ended = after.find((e) => e.event === "ended" && e.sessionId === live.sid);
      expect(ended.detail).toBe(`device_removed:${removedRole}`);
      // Names survive removal, so the app can label rows for a device no longer listed.
      expect(ended.viewerName).toBe("Laptop");
      expect(ended.hostName).toBe("Studio");
      const removal = after.find((e) => e.event === "device_removed");
      expect([removal.deviceId, removal.deviceName]).toEqual([removed.id, removed.name]);
    });
  }
});
