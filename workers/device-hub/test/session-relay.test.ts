import { describe, expect, it, vi } from "vitest";
import { platformUserIdFor } from "../src/machine";
import { ANCHOR_RELAY_TTL_MS, PLAN_UNREAD } from "../src/userDo";
import { BASE, Device, STACK_PROJECT, billingPlans, mockOutbound, platformMachines, rawCall, signIn, worker } from "./helpers";

// A session's viewer and host are one account, so the viewer's billing answer covers the host
// end too: a paid account's joined machine (a machine session, no Stack token) and a Mac whose
// anchor's relay answer has lapsed get the relay for a share a paid viewer starts. A free
// answer grants nothing to either end. A failed billing read is not a free plan: it never
// overwrites a paid answer read in the last 24 h, and with none behind it both ends are told
// "could not read your plan" (`relay: "unread"`) instead of a silent empty relay list.

const TURN = [
  { urls: ["stun:stun.cloudflare.com:3478"] },
  { urls: ["turn:turn.cloudflare.com:3478?transport=udp", "turns:turn.cloudflare.com:443?transport=tcp"], username: "u1", credential: "c1" },
];

async function person(plan: "pro" | "free") {
  const sub = `${plan}-${crypto.randomUUID()}`;
  billingPlans.set(sub, { subscriptionPlanId: plan });
  return signIn(sub);
}

/** A desktop `account.sub` joined: signed in with its machine credential, registered, shared, connected. */
async function machineHost(account: Awaited<ReturnType<typeof signIn>>) {
  const credential = `cmm_${crypto.randomUUID().replace(/-/g, "")}`;
  platformMachines.set(credential, {
    machineId: `machine_${crypto.randomUUID().slice(0, 8)}`,
    teamId: "team_01",
    userId: await platformUserIdFor(STACK_PROJECT, account.sub),
    expiresAt: new Date(Date.now() + 30 * 24 * 3600 * 1000).toISOString(),
  });
  const desktop = await Device.create({ userId: account.userId, session: "" }, "Desktop", "linux");
  mockOutbound();
  const res = await rawCall("POST", "/v1/auth/machine", { body: { credential, deviceId: desktop.id } });
  expect(res.status, JSON.stringify(res.json)).toBe(200);
  const host = await Device.create({ userId: res.json.userId, session: res.json.session }, "Desktop", "linux");
  Object.assign(host, { id: desktop.id, signing: desktop.signing, signingKey: desktop.signingKey, agreementKey: desktop.agreementKey });
  await host.register();
  await host.share(true);
  await host.connect();
  return host;
}

/** The host sets the viewer to ask; the viewer asks for a share; the host approves once with its own session. */
async function decidedByHost(host: Device, viewer: Device) {
  const perm = await host.call("PUT", `/v1/permissions/${host.id}/${viewer.id}`, { scope: "ask" });
  expect(perm.status, JSON.stringify(perm.json)).toBe(200);
  const res = await viewer.call("POST", "/v1/sessions", { hostId: host.id, scope: "view" });
  expect(res.json.session.state, JSON.stringify(res.json)).toBe("pending");
  const sid = res.json.session.id as string;
  await host.user!.next((f) => f.type === "session.request" && f.session.id === sid);
  const decided = await host.call("POST", `/v1/sessions/${sid}/decision`, { decision: "once" });
  expect(decided.status, JSON.stringify(decided.json)).toBe(200);
  const vt = await viewer.user!.next((f) => f.type === "session.ticket" && f.sessionId === sid);
  const ht = await host.user!.next((f) => f.type === "session.ticket" && f.sessionId === sid);
  return { sid, vt, ht };
}

describe("a session's relay follows its viewer's billing answer", () => {
  it("paid viewer, joined machine host: the relay on both ends, approved by the host or not", async () => {
    const account = await person("pro");
    const host = await machineHost(account);
    const viewer = await Device.create(account, "Laptop", "macos");
    await viewer.register();
    await viewer.connect();

    const d = await decidedByHost(host, viewer);
    expect(d.vt.ice).toEqual(TURN);
    expect(d.ht.ice).toEqual(TURN);
    expect([d.vt.relay, d.ht.relay, d.vt.relayNote]).toEqual(["paid", "paid", undefined]);
    // The host's own refresh, with its machine session (no Stack token), gets it too.
    expect((await host.call("POST", `/v1/sessions/${d.sid}/ice`)).json.ice).toEqual(TURN);
  });

  it("the viewer's paid answer covers the host end for 24 h only, and a failed read does not clear it", async () => {
    const sub = `pro-${crypto.randomUUID()}`;
    billingPlans.set(sub, { subscriptionPlanId: "pro" });
    const account = await signIn(sub);
    const host = await machineHost(account);
    const viewer = await Device.create(account, "Laptop", "macos");
    await viewer.register();
    await viewer.connect();
    const d = await decidedByHost(host, viewer);
    expect((await host.call("POST", `/v1/sessions/${d.sid}/ice`)).json.ice).toEqual(TURN);
    // Billing fails on the viewer's next read: an error is not a free plan, so the paid answer
    // read minutes ago still covers both ends.
    billingPlans.set(sub, { status: 500 });
    const failed = (await viewer.call("POST", `/v1/sessions/${d.sid}/ice`)).json;
    expect([failed.ice, failed.relay]).toEqual([TURN, "paid"]);
    expect((await host.call("POST", `/v1/sessions/${d.sid}/ice`)).json.ice).toEqual(TURN);
    // Paid again, then a day passes with no viewer read: the host end's stored answer lapses.
    billingPlans.set(sub, { subscriptionPlanId: "pro" });
    expect((await viewer.call("POST", `/v1/sessions/${d.sid}/ice`)).json.ice).toEqual(TURN);
    vi.useFakeTimers({ toFake: ["Date"], now: Date.now() + ANCHOR_RELAY_TTL_MS + 60_000 });
    try {
      const after = await host.call("POST", `/v1/sessions/${d.sid}/ice`, undefined);
      // The machine session itself may have ended by then; either way no relay is minted.
      expect(after.json.ice ?? []).toEqual([]);
    } finally {
      vi.useRealTimers();
    }
  });

  it("free viewer, joined machine host: no relay on either end", async () => {
    const account = await person("free");
    const host = await machineHost(account);
    const viewer = await Device.create(account, "Laptop", "macos");
    await viewer.register();
    await viewer.connect();

    const d = await decidedByHost(host, viewer);
    expect(d.vt.ice).toEqual([]);
    expect(d.ht.ice).toEqual([]);
    // Free is said as free, never as a failed read.
    expect([d.vt.relay, d.ht.relay, d.vt.relayNote, d.ht.relayNote]).toEqual(["free", "free", undefined, undefined]);
    const ice = (await host.call("POST", `/v1/sessions/${d.sid}/ice`)).json;
    expect([ice.ice, ice.relay]).toEqual([[], "free"]);
    expect((await viewer.call("GET", "/v1/me")).json.planNote).toBeUndefined();
  });

  it("a billing read that fails grants nothing", async () => {
    const sub = `down-${crypto.randomUUID()}`;
    billingPlans.set(sub, { status: 500 });
    const account = await signIn(sub);
    const host = await machineHost(account);
    const viewer = await Device.create(account, "Laptop", "macos");
    await viewer.register();
    await viewer.connect();
    const d = await decidedByHost(host, viewer);
    expect([d.vt.ice, d.ht.ice]).toEqual([[], []]);
    // Both ends are told the plan could not be read, not that it is free.
    expect([d.vt.relay, d.ht.relay]).toEqual(["unread", "unread"]);
    expect([d.vt.relayNote, d.ht.relayNote]).toEqual([PLAN_UNREAD, PLAN_UNREAD]);
    const hostIce = (await host.call("POST", `/v1/sessions/${d.sid}/ice`)).json;
    expect([hostIce.ice, hostIce.relay, hostIce.relayNote]).toEqual([[], "unread", PLAN_UNREAD]);
    const me = (await viewer.call("GET", "/v1/me")).json;
    expect([me.plan, me.planNote]).toEqual(["free", PLAN_UNREAD]);
    // Billing answers again: the next read stores it and the note goes.
    billingPlans.set(sub, { subscriptionPlanId: "pro" });
    const back = (await viewer.call("POST", `/v1/sessions/${d.sid}/ice`)).json;
    expect([back.ice, back.relay, back.relayNote]).toEqual([TURN, "paid", undefined]);
    expect((await host.call("POST", `/v1/sessions/${d.sid}/ice`)).json.ice).toEqual(TURN);
  });

  it("paid viewer, Mac host anchored over 24 h ago: the relay on both ends", async () => {
    const sub = `pro-${crypto.randomUUID()}`;
    billingPlans.set(sub, { subscriptionPlanId: "pro" });
    const first = await signIn(sub);
    const mac = await Device.create(first, "Studio", "macos");
    await mac.register();
    await mac.share(true);
    expect((await mac.call("POST", "/v1/auth/device/anchor", {})).status).toBe(200);

    vi.useFakeTimers({ toFake: ["Date"], now: Date.now() + ANCHOR_RELAY_TTL_MS + 60_000 });
    try {
      const body = JSON.stringify({ userId: first.userId });
      const headers = { ...(await mac.headers("POST", "/v1/auth/device", body)), "content-type": "application/json" };
      const renewed = (await (await worker.fetch(`${BASE}/v1/auth/device`, { method: "POST", headers, body })).json()) as any;
      expect(typeof renewed.session).toBe("string");
      const host = await Device.create({ userId: first.userId, session: renewed.session }, "Studio", "macos");
      Object.assign(host, { id: mac.id, signing: mac.signing, signingKey: mac.signingKey, agreementKey: mac.agreementKey });
      // The anchor's relay answer has lapsed: the host session alone gets none.
      expect((await host.call("GET", "/v1/me")).json.plan).toBe("free");
      await host.connect();

      const account = await signIn(sub);
      const viewer = await Device.create(account, "Laptop", "macos");
      await viewer.register();
      await viewer.connect();
      const d = await decidedByHost(host, viewer);
      expect(d.vt.ice).toEqual(TURN);
      expect(d.ht.ice).toEqual(TURN);
      expect((await host.call("POST", `/v1/sessions/${d.sid}/ice`)).json.ice).toEqual(TURN);
    } finally {
      vi.useRealTimers();
    }
  });

  it("a host session with no paid viewer answer still gets only its own", async () => {
    const account = await person("pro");
    const host = await machineHost(account);
    // No viewer has asked billing for any session: /me reads the machine session's own answer.
    expect((await host.call("GET", "/v1/me")).json.plan).toBe("free");
  });
});
