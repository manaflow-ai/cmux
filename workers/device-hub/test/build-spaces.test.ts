import { runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { spaceOf, userObjectName } from "../src/buildSpace";
import { ApiError } from "../src/errors";
import { BASE, BUILD_SPACE_HEADER, Device, approvedSession, hubEnv, mockOutbound, rawCall, setup, signIn, stackClaims, stackToken, waitFor, worker } from "./helpers";

/**
 * Build spaces (src/buildSpace.ts, PROTOCOL.md "Build spaces"): one person signed in to a NIGHTLY (no header)
 * and to two tagged dev builds (`dev:tag-a`, `dev:tag-b`) on the one dev hub. Every DEV Mac and Debug iPhone of
 * every tag uses that hub, so before spaces a tag's phone listed, and asked to share, every build's Mac of the
 * same account. Each space now has its own User DO: its own devices, permissions, sessions and audit.
 */

const names = async (d: Device) => ((await d.call("GET", "/v1/devices")).json.devices as { name: string }[]).map((x) => x.name).sort();

async function mac(account: Awaited<ReturnType<typeof signIn>>, name: string) {
  const d = await Device.create(account, name, "macos");
  await d.register();
  await d.share(true);
  await d.connect();
  return d;
}

describe("build spaces", () => {
  it("a tagged build's iPhone lists and reaches only its own space's Macs", async () => {
    const sub = `user-${crypto.randomUUID()}`;
    const nightly = await signIn(sub);
    const a = await signIn(sub, undefined, "dev:tag-a");
    const b = await signIn(sub, undefined, "dev:tag-b");
    // One account: the hub user is the same in every space; only the objects are apart.
    expect(new Set([nightly.userId, a.userId, b.userId]).size).toBe(1);
    const macs = { nightly: await mac(nightly, "Nightly Mac"), a: await mac(a, "Tag A Mac"), b: await mac(b, "Tag B Mac") };
    const phoneA = await Device.create(a, "iPhone A", "ios");
    await phoneA.register();
    const phoneN = await Device.create(nightly, "iPhone", "ios");
    await phoneN.register();

    expect(await names(phoneA)).toEqual(["Tag A Mac", "iPhone A"]);
    expect(await names(phoneN)).toEqual(["Nightly Mac", "iPhone"]);
    expect(await names(macs.b)).toEqual(["Tag B Mac"]);

    // Another build's Mac is not a device of this space: a share asked for it is refused, nothing is pushed to it.
    for (const other of [macs.nightly, macs.b]) {
      const cross = await phoneA.call("POST", "/v1/sessions", { hostId: other.id, scope: "view" });
      expect([cross.status, cross.json.error.code]).toEqual([404, "not_found"]);
      expect(await other.user!.none((f) => f.type === "session.request" || f.type === "session.ticket")).toBe(true);
    }
    // Its own space's Mac answers as before.
    const own = await phoneA.call("POST", "/v1/sessions", { hostId: macs.a.id, scope: "view" });
    expect(own.status, JSON.stringify(own.json)).toBe(200);
  });

  it("a hub session works only in the space it was signed in to; another space is an account refusal", async () => {
    const sub = `user-${crypto.randomUUID()}`;
    const a = await signIn(sub, undefined, "dev:tag-a");
    const nightly = await signIn(sub);
    const devMac = await Device.create(a, "Tag A Mac", "macos");
    await devMac.register();
    const nightlyMac = await Device.create(nightly, "Nightly Mac", "macos");
    await nightlyMac.register();
    // 401 unauthorized: the app's client signs in again (exchanges its Stack token) with its own header.
    for (const space of ["dev:tag-b", null]) {
      const res = await devMac.call("GET", "/v1/me", undefined, { space });
      expect([res.status, res.json.error.code], String(space)).toEqual([401, "unauthorized"]);
    }
    const res = await nightlyMac.call("GET", "/v1/me", undefined, { space: "dev:tag-a" });
    expect([res.status, res.json.error.code]).toEqual([401, "unauthorized"]);
    // The socket too.
    const headers = { ...(await devMac.headers("GET", "/v1/user/ws", "")), authorization: `Bearer ${a.session}`, upgrade: "websocket" };
    expect((await worker.fetch(`${BASE}/v1/user/ws`, { headers })).status).toBe(401);
    expect((await devMac.call("GET", "/v1/me")).status).toBe(200);
  });

  it("refuses a header that is not a space, and the reserved dev:default", async () => {
    mockOutbound();
    const token = await stackToken(stackClaims(`user-${crypto.randomUUID()}`));
    for (const value of ["Dev:Tag", "dev:", "dev:-a", "dev:a-", "dev:a_b", "dev:a.b", "nightly", "", "dev:default", `dev:${"a".repeat(65)}`]) {
      const res = await rawCall("POST", "/v1/auth/stack", { body: { token }, headers: { [BUILD_SPACE_HEADER]: value } });
      expect([res.status, res.json.error.code], value).toEqual([400, "build_space.invalid"]);
    }
    const ok = await rawCall("POST", "/v1/auth/stack", { body: { token }, headers: { [BUILD_SPACE_HEADER]: `dev:${"a".repeat(64)}` } });
    expect(ok.status).toBe(200);
  });

  it("serves dev spaces only on the dev hub: production, and an environment it does not know, refuse them", () => {
    const req = (value?: string) => new Request(`${BASE}/v1/me`, { headers: value === undefined ? {} : { [BUILD_SPACE_HEADER]: value } });
    const refusal = (fn: () => unknown) => {
      try {
        fn();
      } catch (err) {
        return err instanceof ApiError ? [err.status, err.code] : String(err);
      }
      return "served";
    };
    for (const ENVIRONMENT of ["production", undefined, "", "prod", "Production", "staging"]) {
      expect(refusal(() => spaceOf(req("dev:tag-a"), { ENVIRONMENT })), String(ENVIRONMENT)).toEqual([403, "build_space.not_allowed"]);
      // NIGHTLY and release send no header: served as before.
      expect(spaceOf(req(), { ENVIRONMENT })).toBe("");
      // A malformed value is malformed everywhere.
      expect(refusal(() => spaceOf(req("Dev:x"), { ENVIRONMENT }))).toEqual([400, "build_space.invalid"]);
    }
    for (const ENVIRONMENT of ["dev", "test", "local"]) expect(spaceOf(req("dev:tag-a"), { ENVIRONMENT })).toBe("dev:tag-a");
    // The test Worker runs as `test`.
    expect(hubEnv.ENVIRONMENT).toBe("test");
  });

  it("names a dev space's User DO apart from nightly's, so no stable user id names it", () => {
    expect(userObjectName("", "p:u")).toBe("p:u");
    expect(userObjectName("dev:tag-a", "p:u")).toBe("dev:tag-a|p:u");
    expect(hubEnv.USER_DO.idFromName(userObjectName("dev:tag-a", "p:u")).toString()).not.toBe(hubEnv.USER_DO.idFromName("p:u").toString());
  });

  it("runs a dev space's session end to end: its signaling reports reach that space's User DO", async () => {
    const account = await signIn(undefined, undefined, "dev:tag-a");
    const { host, viewer } = await setup({ account });
    const s = await approvedSession(host, viewer);
    const v = (await viewer.signal(s.vt)).peer!;
    const h = (await host.signal(s.ht)).peer!;
    v.send({ type: "bye" });
    await h.waitClosed();
    const res = await waitFor(() => host.call("GET", "/v1/audit?limit=200"), (x) => x.json.entries.some((e: any) => e.event === "ended" && e.sessionId === s.sid));
    const events = (res.json.entries as any[]).filter((e) => e.sessionId === s.sid).map((e) => e.event);
    expect(events).toContain("started");
    // Nightly's User DO of the same account never saw it.
    const base = hubEnv.USER_DO.get(hubEnv.USER_DO.idFromName(account.userId));
    const seen = await runInDurableObject(base, (_i, state) => {
      const exists = state.storage.sql.exec("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'audit'").toArray().length > 0;
      return exists ? state.storage.sql.exec("SELECT COUNT(*) AS n FROM audit").one().n : 0;
    });
    expect(seen).toBe(0);
  });

  it("renews cmux Remote's host session in the space that anchored it", async () => {
    const account = await signIn(undefined, undefined, "dev:tag-a");
    const remote = await Device.create(account, "Studio", "macos");
    await remote.register();
    expect((await remote.call("POST", "/v1/auth/device/anchor", {})).status).toBe(200);
    const renew = async (space: string | null) => {
      const body = JSON.stringify({ userId: account.userId });
      const headers = { ...(await remote.headers("POST", "/v1/auth/device", body)), ...remote.spaceHeaders(space), "content-type": "application/json" };
      const res = await worker.fetch(`${BASE}/v1/auth/device`, { method: "POST", headers, body });
      return { status: res.status, json: (await res.json()) as any };
    };
    const own = await renew("dev:tag-a");
    expect(own.status, JSON.stringify(own.json)).toBe(200);
    expect((await remote.call("GET", "/v1/devices", undefined, { session: own.json.session })).status).toBe(200);
    // Nightly's User DO, and another tag's, never anchored this device.
    for (const space of [null, "dev:tag-b"]) expect((await renew(space)).status, String(space)).toBe(401);
  });
});
