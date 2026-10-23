import { evictDurableObject, runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { base64, base64Decode } from "../src/crypto";
import { PENDING_TTL_MS } from "../src/userDo";
import { Device, approvedSession, hubEnv, setup, signIn } from "./helpers";

const N = 0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551n;
const userStub = (userId: string) => hubEnv.USER_DO.get(hubEnv.USER_DO.idFromName(userId));

/** The other valid signature of the same message: (r, n - s). */
function flipS(sigB64: string): string {
  const sig = base64Decode(sigB64);
  const s = BigInt("0x" + [...sig.slice(32)].map((b) => b.toString(16).padStart(2, "0")).join(""));
  const hex = (N - s).toString(16).padStart(64, "0");
  const out = new Uint8Array(64);
  out.set(sig.slice(0, 32));
  for (let i = 0; i < 32; i++) out[32 + i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  return base64(out);
}

describe("replay cache", () => {
  it("refuses a replay that flips the signature's S", async () => {
    const account = await signIn();
    const d = await Device.create(account);
    await d.register();
    // WebCrypto accepts the flipped form of an unused request...
    const fresh = await d.headers("GET", "/v1/devices", "");
    const flippedFresh = await d.call("GET", "/v1/devices", undefined, { headers: { ...fresh, "x-device-sig": flipS(fresh["x-device-sig"]!) } });
    expect(flippedFresh.status).toBe(200);
    // ...so the original of that request is a replay,
    const original = await d.call("GET", "/v1/devices", undefined, { headers: { ...fresh } });
    expect([original.status, original.json.error.code]).toEqual([401, "replay"]);
    // and so is the flipped form of a used one.
    const used = await d.call("GET", "/v1/me");
    expect(used.status).toBe(200);
    const flipped = await d.call("GET", "/v1/me", undefined, { headers: { ...used.headers, "x-device-sig": flipS(used.headers["x-device-sig"]!) } });
    expect([flipped.status, flipped.json.error.code]).toEqual([401, "replay"]);
  });
});

describe("owner fields", () => {
  it("writes owner_kind 'user' and the user id on devices, permissions, sessions and audit", async () => {
    const { account, host, viewer } = await setup();
    await approvedSession(host, viewer);
    const owners = await runInDurableObject(userStub(account.userId), (_i, s) =>
      ["devices", "permissions", "sessions", "audit", "relays"].map((t) => {
        try {
          return [t, s.storage.sql.exec(`SELECT DISTINCT owner_kind AS k, owner_id AS id FROM ${t}`).toArray()];
        } catch (e) {
          return [t, String(e)];
        }
      }),
    );
    for (const [t, rows] of owners.filter(([t]) => t !== "relays")) {
      expect(rows, t as string).toEqual([{ k: "user", id: account.userId }]);
    }
  });

  it("adds and backfills the owner columns in an existing User DO", async () => {
    const { account, host, viewer } = await setup();
    await approvedSession(host, viewer);
    const stub = userStub(account.userId);
    await runInDurableObject(stub, (_i, s) => {
      for (const t of ["devices", "permissions", "sessions", "audit"]) {
        s.storage.sql.exec(`ALTER TABLE ${t} DROP COLUMN owner_kind`);
        s.storage.sql.exec(`ALTER TABLE ${t} DROP COLUMN owner_id`);
      }
      s.storage.sql.exec("ALTER TABLE audit DROP COLUMN device_id");
    });
    await evictDurableObject(stub, { webSockets: "close" });
    expect((await viewer.call("GET", "/v1/devices")).status).toBe(200);
    const owners = await runInDurableObject(stub, (_i, s) =>
      ["devices", "permissions", "sessions", "audit"].map((t) => s.storage.sql.exec(`SELECT DISTINCT owner_kind AS k, owner_id AS id FROM ${t}`).toArray()),
    );
    for (const rows of owners) expect(rows).toEqual([{ k: "user", id: account.userId }]);
  });
});

describe("audit per device includes device events", () => {
  it("lists device_added and device_removed under the affected device", async () => {
    const { host, viewer } = await setup();
    const added = (await host.call("GET", `/v1/audit?limit=200&device=${viewer.id}`)).json.entries as any[];
    expect(added.filter((e) => e.event === "device_added").map((e) => e.deviceId)).toContain(viewer.id);
    await host.call("DELETE", `/v1/devices/${viewer.id}`);
    const removed = (await host.call("GET", `/v1/audit?limit=200&device=${viewer.id}`)).json.entries as any[];
    expect(removed.map((e) => e.event)).toContain("device_removed");
    // The remaining device's History shows the removal too.
    const hostOnly = (await host.call("GET", `/v1/audit?limit=200&device=${host.id}`)).json.entries as any[];
    expect(hostOnly.filter((e) => e.event === "device_removed").map((e) => e.deviceId)).toEqual([viewer.id]);
    expect(hostOnly.filter((e) => e.event === "device_added").map((e) => e.deviceId).sort()).toEqual([host.id, viewer.id].sort());
  });
});

describe("session bookkeeping", () => {
  it("records the path a device reports over signaling, without relaying it", async () => {
    const { account, host, viewer } = await setup();
    const s = await approvedSession(host, viewer);
    const v = (await viewer.signal(s.vt)).peer!;
    const h = (await host.signal(s.ht)).peer!;
    v.send({ type: "path", path: "relay" });
    v.send({ type: "candidate", candidate: "x" });
    await h.next((f) => f.type === "candidate");
    expect(h.frames.some((f) => f.type === "path")).toBe(false);
    const path = await runInDurableObject(userStub(account.userId), (_i, st) => st.storage.sql.exec("SELECT path FROM sessions WHERE id = ?", s.sid).one().path);
    expect(path).toBe("relay");
  });

  it("ends a session whose approval fails instead of leaving it approved", async () => {
    const { host, viewer } = await setup();
    const res = await viewer.call("POST", "/v1/sessions", { hostId: host.id, scope: "view" });
    const sid = res.json.session.id;
    // A Session DO that already exists makes init fail.
    const sdo = hubEnv.SESSION_DO.get(hubEnv.SESSION_DO.idFromName(sid));
    await sdo.fetch("https://session.do/internal/init", {
      method: "POST",
      body: JSON.stringify({ sid, userId: "x", scope: "view", viewer: { id: viewer.id, key: viewer.signingKey }, host: { id: host.id, key: host.signingKey } }),
    });
    const decided = await host.call("POST", `/v1/sessions/${sid}/decision`, { decision: "once" });
    expect(decided.status).toBe(500);
    expect((await viewer.user!.next((f) => f.type === "session.revoked" && f.sessionId === sid)).reason).toBe("approve_failed");
    const again = await host.call("POST", `/v1/sessions/${sid}/decision`, { decision: "once" });
    expect(again.json.error.code).toBe("session_not_pending");
  });

  it("expires a pending request on the server after 5 minutes", async () => {
    const { account, host, viewer } = await setup();
    const res = await viewer.call("POST", "/v1/sessions", { hostId: host.id, scope: "view" });
    const sid = res.json.session.id;
    const stub = userStub(account.userId);
    await runInDurableObject(stub, (_i, s) => {
      s.storage.sql.exec("UPDATE sessions SET created_at = created_at - ? WHERE id = ?", PENDING_TTL_MS + 1000, sid);
    });
    expect(await runDurableObjectAlarm(stub)).toBe(true);
    for (const d of [viewer, host]) {
      expect((await d.user!.next((f) => f.type === "session.revoked" && f.sessionId === sid)).reason).toBe("expired");
    }
    const entries = (await host.call("GET", "/v1/audit?limit=200")).json.entries as any[];
    expect(entries.find((e) => e.event === "ended" && e.sessionId === sid).detail).toBe("expired");
  });
});
