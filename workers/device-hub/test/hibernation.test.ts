import { evictDurableObject, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { Device, approvedSession, hubEnv, setup, signIn } from "./helpers";

describe("User DO WebSockets", () => {
  it("tags sockets by device, answers ping with the auto-response and replaces an older socket", async () => {
    const account = await signIn();
    const d = await Device.create(account);
    await d.register();
    const first = await d.connect();
    const stub = hubEnv.USER_DO.get(hubEnv.USER_DO.idFromName(account.userId));
    const state = await runInDurableObject(stub, (_i, s) => ({
      tags: s.getWebSockets(d.id).map((w) => s.getTags(w)),
      auto: s.getWebSocketAutoResponse(),
    }));
    expect(state.tags).toEqual([[d.id]]);
    expect([state.auto?.request, state.auto?.response]).toEqual(['{"type":"ping"}', '{"type":"pong"}']);
    first.send({ type: "ping" });
    expect(await first.next((f) => f.type === "pong")).toEqual({ type: "pong" });

    const second = await d.connect();
    expect((await first.waitClosed()).code).toBe(4000);
    second.send({ type: "ping" });
    await second.next((f) => f.type === "pong");
    expect(await runInDurableObject(stub, (_i, s) => s.getWebSockets(d.id).length)).toBe(1);
  });

  it("keeps sockets across eviction (hibernation) and still pushes to them", async () => {
    const { account, host, viewer } = await setup();
    const stub = hubEnv.USER_DO.get(hubEnv.USER_DO.idFromName(account.userId));
    await evictDurableObject(stub);
    viewer.user!.send({ type: "ping" });
    expect(await viewer.user!.next((f) => f.type === "pong")).toEqual({ type: "pong" });
    const s = await approvedSession(host, viewer);
    expect(s.vt.role).toBe("viewer");
    const list = await viewer.call("GET", "/v1/devices");
    expect(list.json.devices.every((x: any) => x.online)).toBe(true);
  });

  it("requires a WebSocket upgrade and a signed device", async () => {
    const account = await signIn();
    const d = await Device.create(account);
    await d.register();
    expect((await d.call("GET", "/v1/user/ws")).status).toBe(426);
  });
});
