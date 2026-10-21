import { listDurableObjectIds, runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { mintTicket } from "../src/tickets";
import { approvedSession, auditEvents, hubEnv, setup, waitFor } from "./helpers";

async function sessionStorageKeys(sid: string): Promise<number> {
  const stub = hubEnv.SESSION_DO.get(hubEnv.SESSION_DO.idFromName(sid));
  return runInDurableObject(stub, (_i, state) => state.storage.sql.exec("SELECT COUNT(*) AS n FROM sqlite_master WHERE type = 'table'").one().n as number);
}

/** What an ended Session DO keeps: its meta rows and the row counts of its other tables. */
async function sessionLeftovers(sid: string): Promise<{ meta: string[]; jti: number; queue: number }> {
  const stub = hubEnv.SESSION_DO.get(hubEnv.SESSION_DO.idFromName(sid));
  return runInDurableObject(stub, (_i, state) => ({
    meta: state.storage.sql.exec("SELECT k FROM meta").toArray().map((r) => r.k as string),
    jti: state.storage.sql.exec("SELECT COUNT(*) AS n FROM jti").one().n as number,
    queue: state.storage.sql.exec("SELECT COUNT(*) AS n FROM queue").one().n as number,
  }));
}

describe("tickets", () => {
  it("rejects an expired ticket, a ticket for another device, a replayed jti and a second socket per role", async () => {
    const { host, viewer } = await setup();
    const { sid, vt, ht } = await approvedSession(host, viewer);

    const now = Date.now();
    const expired = await mintTicket(hubEnv, { sid, role: "viewer", dev: viewer.id, peer: host.id, peerKey: host.signingKey, scope: "view" }, now - 61_000);
    const e = await viewer.signal(vt, { ticket: expired });
    expect([e.status, e.json.error.code]).toEqual([401, "ticket_invalid"]);

    // The host presents the viewer's ticket.
    const wrong = await host.signal(vt);
    expect([wrong.status, wrong.json.error.code]).toEqual([403, "ticket_invalid"]);

    // Right ticket, wrong device key.
    const badSig = await viewer.signal(vt, { key: host.signing.privateKey });
    expect([badSig.status, badSig.json.error.code]).toEqual([401, "bad_signature"]);

    const garbage = await viewer.signal(vt, { ticket: "a.b.c" });
    expect(garbage.status).toBe(401);
    const otherSession = await mintTicket(hubEnv, { sid: crypto.randomUUID(), role: "viewer", dev: viewer.id, peer: host.id, peerKey: host.signingKey, scope: "view" });
    expect((await viewer.signal(vt, { ticket: otherSession })).status).toBe(401);

    const first = await viewer.signal(vt);
    expect(first.status).toBe(101);
    const replay = await viewer.signal(vt);
    expect([replay.status, replay.json.error.code]).toEqual([401, "replay"]);

    const second = await mintTicket(hubEnv, { sid, role: "viewer", dev: viewer.id, peer: host.id, peerKey: host.signingKey, scope: "view" });
    const conflict = await viewer.signal(vt, { ticket: second });
    expect([conflict.status, conflict.json.error.code]).toEqual([409, "role_taken"]);

    const h = await host.signal(ht);
    expect(h.status).toBe(101);
    first.peer!.send({ type: "bye" });
    await h.peer!.waitClosed();
  });

  it("refuses tickets for a session that never started on this hub", async () => {
    const { host, viewer } = await setup();
    const sid = crypto.randomUUID();
    const t = await mintTicket(hubEnv, { sid, role: "viewer", dev: viewer.id, peer: host.id, peerKey: host.signingKey, scope: "view" });
    const res = await viewer.signal({ signalURL: `wss://hub.test/v1/sessions/${sid}/ws`, ticket: t });
    expect([res.status, res.json.error.code]).toEqual([404, "session_not_active"]);
  });
});

describe("signaling relay", () => {
  it("relays offer, answer and candidates verbatim, marks the session live, and ends on bye", async () => {
    const { host, viewer } = await setup();
    const { sid, vt, ht } = await approvedSession(host, viewer);
    const v = (await viewer.signal(vt)).peer!;
    // Sent before the host connects: queued, then delivered.
    const offer = JSON.stringify({ type: "offer", sdp: "v=0\r\na=fingerprint:sha-256 AA:BB\r\n", fpSig: "c2ln", extra: { kept: true } });
    v.send(offer);
    const h = (await host.signal(ht)).peer!;
    expect(await h.next((f) => f.type === "offer")).toEqual(JSON.parse(offer));

    await waitFor(() => viewer.call("GET", "/v1/audit"), (r) => r.json.entries.some((e: any) => e.event === "started" && e.sessionId === sid));

    h.send({ type: "answer", sdp: "v=0 answer", fpSig: "c2ln" });
    expect(await v.next((f) => f.type === "answer")).toEqual({ type: "answer", sdp: "v=0 answer", fpSig: "c2ln" });
    v.send({ type: "candidate", candidate: "candidate:1 1 udp 1 1.2.3.4 5 typ host", sdpMid: "0" });
    expect(await h.next((f) => f.type === "candidate")).toMatchObject({ candidate: "candidate:1 1 udp 1 1.2.3.4 5 typ host", sdpMid: "0" });
    // Other message types are dropped.
    v.send({ type: "input", key: "a" });
    v.send("not json");
    expect(await h.none((f) => f.type === "input")).toBe(true);

    h.send({ type: "bye" });
    expect(await v.next((f) => f.type === "bye")).toEqual({ type: "bye" });
    await v.waitClosed();
    await h.waitClosed();
    expect(await host.user!.next((f) => f.type === "session.ended")).toEqual({ type: "session.ended", sessionId: sid, reason: "bye" });
    await viewer.user!.next((f) => f.type === "session.ended");

    const events = await auditEvents(viewer, sid);
    expect(events).toEqual(["requested", "approved", "started", "ended"]);
    const ended = (await viewer.call("GET", "/v1/audit")).json.entries.find((e: any) => e.event === "ended" && e.sessionId === sid);
    expect(ended).toMatchObject({ detail: "bye", scope: "view", viewerId: viewer.id, hostId: host.id });
    expect(typeof ended.durationS).toBe("number");

    // The Session DO deleted its storage but a "closed" marker, which its alarm clears.
    expect(await sessionLeftovers(sid)).toEqual({ meta: ["closed"], jti: 0, queue: 0 });
    expect(await runDurableObjectAlarm(hubEnv.SESSION_DO.get(hubEnv.SESSION_DO.idFromName(sid)))).toBe(true);
    expect(await sessionStorageKeys(sid)).toBe(0);
    const ids = await listDurableObjectIds(hubEnv.SESSION_DO);
    expect(ids.length).toBeGreaterThan(0);
  });

  it("a signaling socket close alone does not end the session", async () => {
    const { host, viewer } = await setup();
    const { sid, vt, ht } = await approvedSession(host, viewer);
    const v = (await viewer.signal(vt)).peer!;
    const h = (await host.signal(ht)).peer!;
    await waitFor(() => auditEvents(viewer, sid), (e) => e.includes("started"));
    v.ws.close(1000, "gone");
    // Longer than the 300 ms test close grace.
    expect(await host.user!.none((f) => f.sessionId === sid && (f.type === "session.ended" || f.type === "session.revoked"), 700)).toBe(true);
    expect(h.closed).toBeNull();
    expect((await viewer.call("POST", `/v1/sessions/${sid}/ice`)).status).toBe(200);
    expect(await auditEvents(viewer, sid)).toEqual(["requested", "approved", "started"]);
    // The session still ends on /end, and closes the host's signaling socket.
    await viewer.call("POST", `/v1/sessions/${sid}/end`, {});
    expect((await host.user!.next((f) => f.type === "session.revoked" && f.sessionId === sid)).reason).toBe("viewer_disconnected");
    await h.waitClosed();
  });
});
