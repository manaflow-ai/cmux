import { describe, expect, it, vi } from "vitest";
import { ANCHOR_TTL_MS } from "../src/userDo";
import { BASE, Device, billingPlans, signIn, worker } from "./helpers";

/** `POST /v1/auth/device` signed by `d` for `userId` (no Stack token). */
async function renew(d: Device, userId = d.account.userId, opts: { key?: CryptoKey } = {}) {
  const body = JSON.stringify({ userId });
  const headers = { ...(await d.headers("POST", "/v1/auth/device", body, opts)), "content-type": "application/json" };
  const res = await worker.fetch(`${BASE}/v1/auth/device`, { method: "POST", headers, body });
  const text = await res.text();
  return { status: res.status, json: text ? (JSON.parse(text) as any) : null };
}

async function anchored() {
  const account = await signIn();
  const mac = await Device.create(account, "Studio", "macos");
  const phone = await Device.create(account, "iPhone", "ios");
  await mac.register();
  await phone.register();
  await mac.share(true);
  const anchor = await mac.call("POST", "/v1/auth/device/anchor", {});
  expect(anchor.status, JSON.stringify(anchor.json)).toBe(200);
  return { account, mac, phone, anchoredUntil: anchor.json.anchoredUntil as number };
}

describe("device-key renewal (cmux Remote with the app quit)", () => {
  it("an anchored Mac renews a host session with its device key alone", async () => {
    const { mac, anchoredUntil } = await anchored();
    expect(anchoredUntil - Date.now()).toBeGreaterThan(ANCHOR_TTL_MS - 60_000);
    const res = await renew(mac);
    expect(res.status, JSON.stringify(res.json)).toBe(200);
    expect(res.json).toMatchObject({ scope: "host", userId: mac.account.userId });
    const host = res.json.session as string;
    // It serves: reads, its socket, its own permissions, sharing off.
    expect((await mac.call("GET", "/v1/devices", undefined, { session: host })).status).toBe(200);
    expect((await mac.call("GET", `/v1/permissions?host=${mac.id}`, undefined, { session: host })).status).toBe(200);
    const headers = { ...(await mac.headers("GET", "/v1/user/ws", "")), authorization: `Bearer ${host}`, upgrade: "websocket" };
    expect((await worker.fetch(`${BASE}/v1/user/ws`, { headers })).status).toBe(101);
  });

  it("a host session cannot raise access, share on, act as a viewer, write relays or anchor", async () => {
    const { mac, phone } = await anchored();
    const host = (await renew(mac)).json.session as string;
    const refused = async (method: string, path: string, body?: unknown) => {
      const res = await mac.call(method, path, body, { session: host });
      expect(res.status, `${method} ${path}`).toBe(403);
      expect(res.json.error.code).toBe("host_scope");
    };
    await refused("PUT", `/v1/devices/${mac.id}/mac-screen`, { shared: true });
    await refused("POST", "/v1/sessions", { hostId: phone.id, scope: "view" });
    await refused("PUT", "/v1/relays/r1", { name: "x", urls: ["turn:x"], authMode: "shared", sealed: {}, enabled: true, priority: 0 });
    await refused("PATCH", `/v1/devices/${phone.id}`, { name: "x" });
    await refused("DELETE", `/v1/devices/${phone.id}`);
    await refused("POST", "/v1/auth/device/anchor", {});
    // Raising a viewer is refused, from Ask (the default) to View or Full.
    await refused("PUT", `/v1/permissions/${mac.id}/${phone.id}`, { scope: "view" });
    await refused("PUT", `/v1/permissions/${mac.id}/${phone.id}`, { scope: "full" });
    // Lowering is allowed: Full (set by the app) to View, then to None; sharing off.
    expect((await mac.call("PUT", `/v1/permissions/${mac.id}/${phone.id}`, { scope: "full" })).status).toBe(200);
    expect((await mac.call("PUT", `/v1/permissions/${mac.id}/${phone.id}`, { scope: "view" }, { session: host })).status).toBe(200);
    await refused("PUT", `/v1/permissions/${mac.id}/${phone.id}`, { scope: "full" });
    expect((await mac.call("PUT", `/v1/permissions/${mac.id}/${phone.id}`, { scope: "none" }, { session: host })).status).toBe(200);
    expect((await mac.call("PUT", `/v1/devices/${mac.id}/mac-screen`, { shared: false }, { session: host })).status).toBe(200);
  });

  it("a host session acts only on sessions where this Mac is the host", async () => {
    const account = await signIn();
    const mac = await Device.create(account, "Studio", "macos");
    const other = await Device.create(account, "Other Mac", "macos");
    await mac.register();
    await other.register();
    await other.share(true);
    await mac.connect();
    await other.connect();
    await mac.call("POST", "/v1/auth/device/anchor", {});
    expect((await other.call("PUT", `/v1/permissions/${other.id}/${mac.id}`, { scope: "view" })).status).toBe(200);
    // This Mac is the viewer of a session to the other Mac (with its full session).
    const asViewer = await mac.call("POST", "/v1/sessions", { hostId: other.id, scope: "view" });
    expect(asViewer.status, JSON.stringify(asViewer.json)).toBe(200);
    const sid = asViewer.json.session.id as string;
    const host = (await renew(mac)).json.session as string;
    for (const d of ["end", "ice"]) {
      const res = await mac.call("POST", `/v1/sessions/${sid}/${d}`, d === "end" ? { reason: "x" } : undefined, { session: host });
      expect(res.status, d).toBe(403);
      expect(res.json.error.code).toBe("host_scope");
    }
  });

  it("the session is that device's only: another device's signature is refused", async () => {
    const { mac, phone } = await anchored();
    const host = (await renew(mac)).json.session as string;
    const res = await phone.call("GET", "/v1/devices", undefined, { session: host });
    expect(res.status).toBe(403);
    expect(res.json.error.code).toBe("host_scope");
  });

  it("without an anchor, with another key, for another account or replayed, renewal is refused", async () => {
    const account = await signIn();
    const mac = await Device.create(account, "Studio", "macos");
    await mac.register();
    expect((await renew(mac)).json.error.code).toBe("not_anchored");
    await mac.call("POST", "/v1/auth/device/anchor", {});
    const thief = await Device.create(account);
    expect((await renew(mac, account.userId, { key: thief.signing.privateKey })).json.error.code).toBe("bad_signature");
    const other = await signIn();
    expect((await renew(mac, other.userId)).status).toBe(401);
    // The same signed request twice: the second is a replay.
    const body = JSON.stringify({ userId: account.userId });
    const headers = { ...(await mac.headers("POST", "/v1/auth/device", body)), "content-type": "application/json" };
    expect((await worker.fetch(`${BASE}/v1/auth/device`, { method: "POST", headers, body })).status).toBe(200);
    expect((await worker.fetch(`${BASE}/v1/auth/device`, { method: "POST", headers, body })).status).toBe(401);
  });

  it("an iPhone is never anchored", async () => {
    const { phone } = await anchored();
    const res = await phone.call("POST", "/v1/auth/device/anchor", {});
    expect(res.status).toBe(403);
  });

  it("removal, sign-out and sharing off end renewal until the app anchors again", async () => {
    for (const end of ["sharing_off", "sign_out", "removed"] as const) {
      const { mac, phone } = await anchored();
      expect((await renew(mac)).status).toBe(200);
      if (end === "sharing_off") await mac.share(false);
      if (end === "sign_out") expect((await mac.call("POST", `/v1/devices/${mac.id}/sign-out`)).status).toBe(200);
      if (end === "removed") expect((await phone.call("DELETE", `/v1/devices/${mac.id}`)).status).toBe(200);
      const after = await renew(mac);
      expect(after.status, end).toBe(403);
      expect(["not_anchored", "device_removed"]).toContain(after.json.error.code);
    }
  });

  it("an anchor lapses after 30 days", async () => {
    const { mac } = await anchored();
    vi.useFakeTimers({ toFake: ["Date"], now: Date.now() + ANCHOR_TTL_MS + 1000 });
    try {
      expect((await renew(mac)).json.error.code).toBe("not_anchored");
    } finally {
      vi.useRealTimers();
    }
  });

  it("a host session's relay entitlement is the anchor's billing answer", async () => {
    const sub = `pro-${crypto.randomUUID()}`;
    billingPlans.set(sub, { subscriptionPlanId: "pro" });
    const account = await signIn(sub);
    const mac = await Device.create(account, "Studio", "macos");
    await mac.register();
    await mac.call("POST", "/v1/auth/device/anchor", {});
    const host = (await renew(mac)).json.session as string;
    // Billing is not asked for a host session (it has no Stack token).
    billingPlans.set(sub, { status: 500 });
    expect((await mac.call("GET", "/v1/me", undefined, { session: host })).json.plan).toBe("paid");
  });
});
