import { describe, expect, it } from "vitest";
import { billingOrigin } from "../src/billing";
import { type BillingAnswer, approvedSession, billingCalls, billingPlans, setup, signIn, STACK_DEV_PROJECT } from "./helpers";

const CMUX_ICE = [
  { urls: ["stun:stun.cloudflare.com:3478"] },
  { urls: ["turn:turn.cloudflare.com:3478?transport=udp", "turns:turn.cloudflare.com:443?transport=tcp"], username: "u1", credential: "c1" },
];

/** A signed-in user with two connected devices whose billing answers `answer`. */
async function userOn(answer: BillingAnswer | null, project?: string) {
  const sub = `billing-${crypto.randomUUID()}`;
  if (answer !== null) billingPlans.set(sub, answer);
  const account = await signIn(sub, project);
  const { host, viewer } = await setup({ account });
  return { sub, account, host, viewer };
}

/** The ICE a fresh session's tickets carry, and what `/ice` returns for it. */
async function relayFor(u: Awaited<ReturnType<typeof userOn>>) {
  const { sid, vt, ht } = await approvedSession(u.host, u.viewer);
  const ice = await u.viewer.call("POST", `/v1/sessions/${sid}/ice`);
  expect(ice.status).toBe(200);
  await u.viewer.call("POST", `/v1/sessions/${sid}/end`, { reason: "done" });
  return { viewerTicket: vt.ice, hostTicket: ht.ice, refreshed: ice.json.ice };
}

describe("cmux relay entitlement (cmux billing)", () => {
  it.each([
    ["pro", { subscriptionPlanId: "pro" }],
    ["max", { subscriptionPlanId: "max" }],
    ["a paid team (personal plan free)", { subscriptionPlanId: "free", teamPlanId: "team" }],
    ["a paid team (personal plan go)", { subscriptionPlanId: "go", teamPlanId: "team" }],
  ] as const)("gives the cmux relay to %s", async (_, answer) => {
    const r = await relayFor(await userOn(answer));
    expect(r).toEqual({ viewerTicket: CMUX_ICE, hostTicket: CMUX_ICE, refreshed: CMUX_ICE });
  });

  it.each([
    ["free", { subscriptionPlanId: "free" }],
    ["go", { subscriptionPlanId: "go" }],
    ["an unknown plan id", { subscriptionPlanId: "founders-plus" }],
    ["a user with no billing record", null],
  ] as const)("gives no cmux relay to %s", async (_, answer) => {
    expect(await relayFor(await userOn(answer))).toEqual({ viewerTicket: [], hostTicket: [], refreshed: [] });
  });

  it.each([
    ["a 500", { status: 500 }],
    ["a 401", { status: 401 }],
    ["a redirect", { status: 302 }],
    ["a body that is not JSON", "not-json"],
    ["a network failure", "network"],
    ["a timeout", "hang"],
    ["an unauthenticated answer", { subscriptionPlanId: "pro", authenticated: false }],
    ["another user's plan", { subscriptionPlanId: "pro", userId: "someone-else" }],
  ] as const)("fails closed on %s: no cmux relay, the session still starts", async (_, answer) => {
    const u = await userOn(answer);
    const r = await relayFor(u);
    expect(r).toEqual({ viewerTicket: [], hostTicket: [], refreshed: [] });
  });

  it("checks again for every ticket and refresh: a lapsed plan gets no relay on the next one", async () => {
    const u = await userOn({ subscriptionPlanId: "pro" });
    const first = await approvedSession(u.host, u.viewer);
    expect(first.vt.ice).toEqual(CMUX_ICE);
    // The subscription lapses while the first session is still live.
    billingPlans.set(u.sub, { subscriptionPlanId: "free" });
    expect((await u.viewer.call("POST", `/v1/sessions/${first.sid}/ice`)).json.ice).toEqual([]);
    await u.viewer.call("POST", `/v1/sessions/${first.sid}/end`, { reason: "done" });
    const second = await approvedSession(u.host, u.viewer);
    expect([second.vt.ice, second.ht.ice]).toEqual([[], []]);
    // And a renewed plan gets it back at once.
    billingPlans.set(u.sub, { subscriptionPlanId: "max" });
    expect((await u.viewer.call("POST", `/v1/sessions/${second.sid}/ice`)).json.ice).toEqual(CMUX_ICE);
  });

  it("asks the user's own Stack project's backend with the user's own Stack token, and never echoes it", async () => {
    for (const project of [undefined, STACK_DEV_PROJECT]) {
      const u = await userOn({ subscriptionPlanId: "pro" }, project);
      const before = billingCalls.length;
      const { sid, vt } = await approvedSession(u.host, u.viewer);
      const calls = billingCalls.slice(before).filter((c) => c.sub === u.sub);
      expect(calls.length).toBeGreaterThan(0);
      for (const c of calls) {
        expect(c.accessToken).toBe(u.account.stackToken);
        expect(c.origin).toBe(project === STACK_DEV_PROJECT ? "https://billing-dev.test" : "https://billing.test");
      }
      // Neither the ticket push nor any answer carries the Stack token.
      expect(JSON.stringify(vt)).not.toContain(u.account.stackToken.split(".")[2]);
      const me = await u.viewer.call("GET", "/v1/me");
      expect(JSON.stringify(me.json)).not.toContain(u.account.stackToken.split(".")[2]);
      await u.viewer.call("POST", `/v1/sessions/${sid}/end`, { reason: "done" });
    }
  });

  it("uses the session's own Stack token, not one a client sends in the internal header", async () => {
    const u = await userOn({ subscriptionPlanId: "free" });
    const paidSub = `billing-${crypto.randomUUID()}`;
    billingPlans.set(paidSub, { subscriptionPlanId: "pro" });
    const paid = await signIn(paidSub);
    const before = billingCalls.length;
    const me = await u.viewer.call("GET", "/v1/me", undefined, { extraHeaders: { "x-hub-stack-token": paid.stackToken } });
    expect(me.json.plan).toBe("free");
    expect(billingCalls.slice(before).map((c) => c.sub)).toEqual([u.sub]);
  });
});

describe("BILLING_ORIGINS", () => {
  it("maps a project to exactly an https origin, else none", () => {
    const env = (v: string) => ({ BILLING_ORIGINS: v });
    expect(billingOrigin(env("p=https://cmux.com,q=https://staging.example"), "q")).toBe("https://staging.example");
    expect(billingOrigin(env("p=https://cmux.com/"), "p")).toBe("https://cmux.com");
    expect(billingOrigin(env("p=https://cmux.com"), "other")).toBeNull();
    expect(billingOrigin({}, "p")).toBeNull();
    for (const bad of ["http://cmux.com", "https://cmux.com/api", "https://cmux.com?x=1", "https://cmux.com#x", "https://u:p@cmux.com", "cmux.com", ""]) {
      expect(billingOrigin(env(`p=${bad}`), "p"), bad).toBeNull();
    }
  });
});
