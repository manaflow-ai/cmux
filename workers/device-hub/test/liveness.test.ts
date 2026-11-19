import { evictDurableObject, runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { afterEach, describe, expect, it, vi } from "vitest";
import { INTERNAL_CALL_TIMEOUT_MS, internalCall } from "../src/internalCall";
import { SILENT_CLOSE, SILENT_MS } from "../src/userDo";
import { type Device, type Peer, approvedSession, hubEnv, setup, waitFor } from "./helpers";

const userStub = (userId: string) => hubEnv.USER_DO.get(hubEnv.USER_DO.idFromName(userId));
const sessionStub = (sid: string) => hubEnv.SESSION_DO.get(hubEnv.SESSION_DO.idFromName(sid));

/** The device's socket attachment and the User DO's next alarm. */
async function socketClock(userId: string, deviceId: string) {
  return runInDurableObject(userStub(userId), async (_i, s) => {
    const ws = s.getWebSockets(deviceId).find((w) => !(w.deserializeAttachment() as { closed?: boolean } | null)?.closed);
    return { attachment: (ws?.deserializeAttachment() ?? null) as { openedAt?: number; heardAt?: number } | null, alarm: await s.storage.getAlarm() };
  });
}

/**
 * Moves the DOs' clock (Date only; timers stay real) to `at`. A ping's
 * auto-response timestamp is the runtime's real time, so under the moved clock a
 * device that should stay alive says so with another frame, which the User DO
 * records with the moved clock; this waits until it has.
 */
async function moveClockTo(at: number, account: { userId: string }, alive: Device[]) {
  vi.useFakeTimers({ toFake: ["Date"], now: at });
  for (const d of alive) {
    d.user!.send({ type: "here" });
    await waitFor(() => socketClock(account.userId, d.id), (c) => (c.attachment?.heardAt ?? 0) >= at);
  }
}

async function online(observer: Device, deviceId: string): Promise<boolean> {
  const list = await observer.call("GET", "/v1/devices");
  return list.json.devices.find((x: any) => x.id === deviceId).online;
}

/** Lets the socket's own close event land, then says whether it is still open. */
async function stillOpen(p: Peer): Promise<boolean> {
  try {
    await p.waitClosed(200);
    return false;
  } catch {
    return true;
  }
}

afterEach(() => {
  vi.useRealTimers();
});

describe("User DO: a device that goes silent without closing its socket", () => {
  it("silent right after it connects: offline at the bound, socket closed with why, sessions end peer_offline", async () => {
    const { account, host, viewer } = await setup();
    const s = await approvedSession(host, viewer);
    const { attachment, alarm } = await socketClock(account.userId, viewer.id);
    const openedAt = attachment!.openedAt!;
    expect(typeof openedAt).toBe("number");
    // The check is already scheduled no later than the bound: connecting arms it.
    expect(alarm).not.toBeNull();
    expect(alarm! - openedAt).toBeLessThanOrEqual(SILENT_MS);

    // Just inside the bound the viewer is still online and its session stands.
    await moveClockTo(openedAt + SILENT_MS - 1000, account, [host]);
    await runDurableObjectAlarm(userStub(account.userId));
    expect(await stillOpen(viewer.user!)).toBe(true);
    expect(await online(host, viewer.id)).toBe(true);
    expect(await host.user!.none((f) => f.type === "session.ended")).toBe(true);

    // Past the bound: found silent, closed with a reason, and every other device hears.
    await moveClockTo(openedAt + SILENT_MS + 1000, account, [host]);
    while (host.user!.frames.some((f) => f.type === "devices.changed")) await host.user!.next((f) => f.type === "devices.changed");
    expect(await runDurableObjectAlarm(userStub(account.userId))).toBe(true);
    const closed = await viewer.user!.waitClosed();
    expect(closed.code).toBe(SILENT_CLOSE);
    expect(closed.reason).toMatch(/^silent \d+ s: no ping within 75 s$/);
    expect(await host.user!.next((f) => f.type === "devices.changed")).toEqual({ type: "devices.changed" });
    expect(await online(host, viewer.id)).toBe(false);
    // Its offline grace counts from when it was last heard, so the session ends in the same pass.
    expect(await host.user!.next((f) => f.type === "session.ended" && f.sessionId === s.sid)).toEqual({ type: "session.ended", sessionId: s.sid, reason: "peer_offline" });
    const entries = (await host.call("GET", "/v1/audit?limit=200")).json.entries as any[];
    expect(entries.find((e) => e.event === "ended" && e.sessionId === s.sid).detail).toBe("peer_offline");
  });

  it("silent mid-session: offline within the bound of its last frame, signaling sockets closed, peer_offline", async () => {
    const { account, host, viewer } = await setup();
    const s = await approvedSession(host, viewer);
    const v = (await viewer.signal(s.vt)).peer!;
    const h = (await host.signal(s.ht)).peer!;
    await waitFor(() => viewer.call("GET", "/v1/audit"), (r) => r.json.entries.some((e: any) => e.event === "started" && e.sessionId === s.sid));

    // Both talk for a while, then the viewer's link dies with no FIN.
    const t0 = Date.now() + 120_000;
    await moveClockTo(t0, account, [host, viewer]);
    const lastHeard = (await socketClock(account.userId, viewer.id)).attachment!.heardAt!;

    await moveClockTo(lastHeard + SILENT_MS - 1000, account, [host]);
    await runDurableObjectAlarm(userStub(account.userId));
    expect(await stillOpen(viewer.user!)).toBe(true);
    expect(await online(host, viewer.id)).toBe(true);

    await moveClockTo(lastHeard + SILENT_MS + 1000, account, [host]);
    expect(await runDurableObjectAlarm(userStub(account.userId))).toBe(true);
    expect((await viewer.user!.waitClosed()).code).toBe(SILENT_CLOSE);
    expect(await online(host, viewer.id)).toBe(false);
    expect((await host.user!.next((f) => f.type === "session.ended" && f.sessionId === s.sid)).reason).toBe("peer_offline");
    // The Session DO closed both signaling sockets.
    await h.waitClosed();
    await v.waitClosed();
  });

  it("a device that keeps talking stays online past the bound", async () => {
    const { account, host, viewer } = await setup();
    const start = Date.now();
    for (let t = start + 30_000; t <= start + 3 * SILENT_MS; t += 30_000) {
      await moveClockTo(t, account, [host, viewer]);
      await runDurableObjectAlarm(userStub(account.userId));
    }
    expect(await stillOpen(viewer.user!)).toBe(true);
    expect(await online(host, viewer.id)).toBe(true);
  });

  it("arms the silence check for a socket restored from before the check existed", async () => {
    const { account, host, viewer } = await setup();
    const stub = userStub(account.userId);
    // A socket accepted by the old code: no clock, and no alarm pending.
    await runInDurableObject(stub, async (_i, s) => {
      for (const ws of s.getWebSockets()) ws.serializeAttachment(null);
      await s.storage.deleteAlarm();
    });
    await evictDurableObject(stub);
    // Any wake (here a request) arms the check right away.
    expect((await host.call("GET", "/v1/devices")).status).toBe(200);
    // The armed check is due at once: its sweep starts the restored sockets' clocks,
    // and the next check is within the bound.
    const { attachment, alarm } = await waitFor(
      () => socketClock(account.userId, viewer.id),
      (c) => typeof c.attachment?.openedAt === "number" && c.alarm !== null,
    );
    expect(typeof attachment?.openedAt).toBe("number");
    expect(alarm! - attachment!.openedAt!).toBeLessThanOrEqual(SILENT_MS);
  });

  it("a device socket error counts as offline at once, and its sessions end after the grace", async () => {
    const { account, host, viewer } = await setup();
    const s = await approvedSession(host, viewer);
    const stub = userStub(account.userId);
    await runInDurableObject(stub, async (instance: any, st) => {
      await instance.webSocketError(st.getWebSockets(viewer.id)[0], new Error("connection reset"));
    });
    expect(await online(host, viewer.id)).toBe(false);
    expect((await viewer.user!.waitClosed()).code).toBe(1011);
    await runInDurableObject(stub, (_i, st) => {
      st.storage.sql.exec("UPDATE offline SET since = since - 31000");
    });
    await runDurableObjectAlarm(stub);
    expect((await host.user!.next((f) => f.type === "session.ended" && f.sessionId === s.sid)).reason).toBe("peer_offline");
  });

  it("records a ping's auto-response as a sign of life", async () => {
    const { account, viewer } = await setup();
    viewer.user!.send({ type: "ping" });
    await viewer.user!.next((f) => f.type === "pong");
    const ts = await runInDurableObject(userStub(account.userId), (_i, s) => s.getWebSocketAutoResponseTimestamp(s.getWebSockets(viewer.id)[0]!)?.getTime() ?? null);
    expect(ts).not.toBeNull();
  });
});

describe("Session DO: the other side hears when a signaling socket goes", () => {
  it("a socket error tells the remaining peer peer-left with the error", async () => {
    const { host, viewer } = await setup();
    const s = await approvedSession(host, viewer);
    await viewer.signal(s.vt);
    const h = (await host.signal(s.ht)).peer!;
    await runInDurableObject(sessionStub(s.sid), async (instance: any, state) => {
      await instance.webSocketError(state.getWebSockets("viewer")[0], new Error("connection reset"));
    });
    expect(await h.next((f) => f.type === "peer-left")).toEqual({ type: "peer-left", role: "viewer", reason: "error: connection reset" });
    // Once per socket: the close that follows the error does not repeat it.
    expect(await h.none((f) => f.type === "peer-left", 300)).toBe(true);
    // The session itself stands (the peer connection may be up).
    expect(h.closed).toBeNull();
  });

  it("a side that fails before the other joins: the other hears peer-left when it joins", async () => {
    const { host, viewer } = await setup();
    const s = await approvedSession(host, viewer);
    await viewer.signal(s.vt);
    await runInDurableObject(sessionStub(s.sid), async (instance: any, state) => {
      await instance.webSocketError(state.getWebSockets("viewer")[0], new Error("connection reset"));
    });
    const h = (await host.signal(s.ht)).peer!;
    expect(await h.next((f) => f.type === "peer-left")).toEqual({ type: "peer-left", role: "viewer", reason: "error: connection reset" });
  });

  it("a socket close tells the remaining peer peer-left with the code and reason", async () => {
    const { host, viewer } = await setup();
    const s = await approvedSession(host, viewer);
    const v = (await viewer.signal(s.vt)).peer!;
    const h = (await host.signal(s.ht)).peer!;
    v.ws.close(1000, "app quit");
    expect(await h.next((f) => f.type === "peer-left")).toEqual({ type: "peer-left", role: "viewer", reason: "closed 1000: app quit" });
  });

  it("no peer-left after the session ended", async () => {
    const { host, viewer } = await setup();
    const s = await approvedSession(host, viewer);
    const v = (await viewer.signal(s.vt)).peer!;
    const h = (await host.signal(s.ht)).peer!;
    v.send({ type: "bye" });
    await h.next((f) => f.type === "bye");
    expect(await h.none((f) => f.type === "peer-left", 300)).toBe(true);
  });
});

describe("calls between Durable Objects have a deadline", () => {
  it("gives up on a stub that never answers, naming the call and the deadline", async () => {
    const hung = { fetch: () => new Promise<Response>(() => {}) };
    const started = Date.now();
    await expect(internalCall(hung, "https://user.do/internal/session-ended", {}, "session s1 end report", 50)).rejects.toThrow("session s1 end report: no answer within 50 ms");
    expect(Date.now() - started).toBeLessThan(1000);
    expect(INTERNAL_CALL_TIMEOUT_MS).toBe(5000);
  });

  it("leaves no timer behind once a call answers, so the object can be evicted at once", async () => {
    const { account, host, viewer } = await setup();
    // Approval calls the Session DO through internalCall from the User DO.
    await approvedSession(host, viewer);
    const started = Date.now();
    await evictDurableObject(userStub(account.userId), { webSockets: "close" });
    expect(Date.now() - started).toBeLessThan(INTERNAL_CALL_TIMEOUT_MS);
  });

  it("passes the stub's own failure through with the call's name", async () => {
    const broken = { fetch: () => Promise.reject(new Error("object reset")) };
    await expect(internalCall(broken, "https://session.do/internal/close", {}, "session s1 close")).rejects.toThrow("session s1 close: object reset");
  });
});
