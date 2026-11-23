import { describe, expect, mock, test } from "bun:test";
import { NextRequest } from "next/server";

import en from "../messages/en.json";
import { GO_PRICING_USD } from "../services/billing/plans";
import { isCloudIntroRenewChargeEnabled } from "../services/billing/cloudIntro";
import {
  cloudIntroRenewalDue,
  cloudIntroRenewalIdempotencyKey,
  cloudIntroRenewalOutcome,
  runCloudIntroRenewals,
  turnOffRow,
  type CloudIntroRenewalCandidate,
  type CloudIntroRenewalDependencies,
  type CloudIntroRenewalStore,
  type CloudIntroRenewTurnOff,
} from "../services/billing/cloudIntroRenewal";
import {
  buildCloudIntroStatement,
  cloudIntroRenewalView,
  cloudIntroStatementLinks,
  cloudIntroStatementText,
  dueCloudIntroStatement,
  withCurrentRenewal,
  type CloudPassUsage,
} from "../services/billing/cloudIntroStatements";
import { claimedStatementLog, type CloudIntroStatementRow, type CloudIntroStatementStore } from "../services/billing/cloudIntroStatementStore";
import { cloudIntroStatementCopy, runCloudIntroStatements } from "../services/billing/cloudIntroStatementJob";

const captureBillingError = mock(() => {});
const captureCoderouterError = mock(() => {});
mock.module("../services/errors", () => ({ captureBillingError, captureCoderouterError }));

const { cloudIntroRenewResponse } = await import("../services/billing/cloudIntroRenewRoute");

const DAY = 24 * 60 * 60 * 1000;
const STARTED = new Date("2026-11-01T09:30:00.000Z");
const ENDS = new Date(STARTED.getTime() + 30 * DAY);
const PASS_ON = { CMUX_CLOUD_INTRO: "1" };
const CHARGE_ON = { CMUX_CLOUD_INTRO: "1", CMUX_CLOUD_INTRO_RENEW_CHARGE: "1" };
const READ: CloudPassUsage = { status: "read", chiefAwakeMinutes: null, machineMinutes: 900, machinesStarted: 2 };

function onDay(day: number, offsetMs = 0): Date {
  return new Date(STARTED.getTime() + (day - 1) * DAY + offsetMs);
}

function row(overrides: Partial<CloudIntroStatementRow> = {}): CloudIntroStatementRow {
  return {
    checkoutSessionId: "cs_pass_1",
    stackUserId: "user_1",
    status: "granted",
    renewOnPlus: true,
    startedAt: STARTED,
    endsAt: ENDS,
    statements: {},
    stripeCustomerId: "cus_1",
    paymentMethodId: "pm_1",
    renewalStatus: null,
    ...overrides,
  };
}

type Recorded = { status: string; subscriptionId?: string | null; errorCode?: string | null };

/** One table of pass rows shared by the renewal store and the statement store, like the real one. */
function passTable(rows: CloudIntroStatementRow[]) {
  const byId = new Map(rows.map((r) => [r.checkoutSessionId, r]));
  const recorded = new Map<string, Recorded>();
  const candidate = (r: CloudIntroStatementRow): CloudIntroRenewalCandidate => ({
    checkoutSessionId: r.checkoutSessionId,
    stackUserId: r.stackUserId,
    stripeCustomerId: r.stripeCustomerId!,
    paymentMethodId: r.paymentMethodId!,
  });
  const due = (r: CloudIntroStatementRow, now: Date) => cloudIntroRenewalDue({ ...r, renewalStatus: r.renewalStatus ?? null }, now);
  const renewals: CloudIntroRenewalStore = {
    async listDue(now) {
      return [...byId.values()].filter((r) => due(r, now)).map(candidate);
    },
    async claim(id, now) {
      const r = byId.get(id);
      if (!r || !due(r, now)) return null;
      byId.set(id, { ...r, renewalStatus: "started" });
      return candidate(r);
    },
    async record(id, outcome) {
      const r = byId.get(id);
      if (!r || r.renewalStatus !== "started") return;
      byId.set(id, { ...r, renewalStatus: outcome.status });
      recorded.set(id, outcome);
    },
  };
  const statements: CloudIntroStatementStore = {
    async listCandidates() {
      return [...byId.values()];
    },
    async claim(id, now, build) {
      const r = byId.get(id);
      if (!r) return null;
      const d = dueCloudIntroStatement(r, now);
      if (!d) return null;
      const statement = build(r, d);
      if (!statement) return null;
      byId.set(id, { ...r, statements: claimedStatementLog(r.statements, d, statement, now) });
      return { pass: r, day: d.day, statement };
    },
    async markDelivery() {},
    async latestForUser() {
      return null;
    },
  };
  return { byId, recorded, renewals, statements };
}

function fakeStripe(behavior: () => Promise<unknown> = async () => ({ id: "sub_1", status: "active" })) {
  const create = mock(async (_params: unknown, _options: { idempotencyKey: string }) => await behavior());
  return { create, stripe: () => ({ subscriptions: { create } }) as never };
}

function renewalDeps(
  table: ReturnType<typeof passTable>,
  stripe: ReturnType<typeof fakeStripe>,
  overrides: Partial<CloudIntroRenewalDependencies> = {},
): CloudIntroRenewalDependencies {
  return {
    env: CHARGE_ON,
    now: onDay(30),
    store: table.renewals,
    stripe: stripe.stripe,
    plusPriceId: async () => "price_plus_monthly",
    hasPersonalPlan: async () => false,
    ...overrides,
  };
}

function stripeError(type: string, fields: Record<string, unknown> = {}) {
  return Object.assign(new Error(type), { type, ...fields });
}

describe("the flag", () => {
  test("off unless CMUX_CLOUD_INTRO_RENEW_CHARGE=1 and the pass flag are both on, dev included", () => {
    expect(isCloudIntroRenewChargeEnabled({ CMUX_CLOUD_INTRO: "1" })).toBe(false);
    expect(isCloudIntroRenewChargeEnabled({ NODE_ENV: "development", VERCEL_ENV: "development" })).toBe(false);
    expect(isCloudIntroRenewChargeEnabled({ CMUX_CLOUD_INTRO_RENEW_CHARGE: "1", NODE_ENV: "production", VERCEL_ENV: "production" })).toBe(false);
    expect(isCloudIntroRenewChargeEnabled(CHARGE_ON)).toBe(true);
  });
});

describe("the day-30 Plus charge", () => {
  test("happy path: one off-session Plus subscription on the saved customer and card, recorded", async () => {
    const table = passTable([row()]);
    const stripe = fakeStripe();
    const result = await runCloudIntroRenewals(renewalDeps(table, stripe));
    expect(result).toMatchObject({ skipped: false, considered: 1, succeeded: 1 });
    const [params, options] = stripe.create.mock.calls[0]!;
    expect(params).toMatchObject({
      customer: "cus_1",
      items: [{ price: "price_plus_monthly", quantity: 1 }],
      default_payment_method: "pm_1",
      off_session: true,
      payment_behavior: "error_if_incomplete",
      metadata: { app: "cmux", stackUserId: "user_1", plan: "go", billingInterval: "month", cloudIntroCheckoutSessionId: "cs_pass_1" },
    });
    expect(options).toEqual({ idempotencyKey: "cmux-cloud-intro-renew-cs_pass_1" });
    expect(options.idempotencyKey).toBe(cloudIntroRenewalIdempotencyKey("cs_pass_1"));
    expect(table.byId.get("cs_pass_1")!.renewalStatus).toBe("succeeded");
    expect(table.recorded.get("cs_pass_1")).toMatchObject({ status: "succeeded", subscriptionId: "sub_1" });
  });

  test("idempotent rerun: a second run, or one racing the first, charges nothing more", async () => {
    const table = passTable([row()]);
    const stripe = fakeStripe();
    await Promise.all([runCloudIntroRenewals(renewalDeps(table, stripe)), runCloudIntroRenewals(renewalDeps(table, stripe))]);
    const again = await runCloudIntroRenewals(renewalDeps(table, stripe, { now: onDay(30, 3 * 60 * 60 * 1000) }));
    expect(stripe.create).toHaveBeenCalledTimes(1);
    expect(again.considered).toBe(0);
  });

  test("a declined card is recorded as failed and never retried", async () => {
    const table = passTable([row()]);
    const stripe = fakeStripe(async () => {
      throw stripeError("StripeCardError", { code: "card_declined", decline_code: "insufficient_funds" });
    });
    const result = await runCloudIntroRenewals(renewalDeps(table, stripe));
    expect(result).toMatchObject({ failed: 1, succeeded: 0 });
    expect(table.recorded.get("cs_pass_1")).toMatchObject({ status: "failed", errorCode: "insufficient_funds" });
    await runCloudIntroRenewals(renewalDeps(table, stripe, { now: onDay(30, 60 * 60 * 1000) }));
    expect(stripe.create).toHaveBeenCalledTimes(1);
  });

  test("a card that needs the buyer is recorded as requires_action and never retried", async () => {
    const table = passTable([row()]);
    const stripe = fakeStripe(async () => {
      throw stripeError("StripeCardError", { code: "authentication_required", payment_intent: { status: "requires_action" } });
    });
    const result = await runCloudIntroRenewals(renewalDeps(table, stripe));
    expect(result.requiresAction).toBe(1);
    expect(table.byId.get("cs_pass_1")!.renewalStatus).toBe("requires_action");
    await runCloudIntroRenewals(renewalDeps(table, stripe, { now: onDay(30, 60 * 60 * 1000) }));
    expect(stripe.create).toHaveBeenCalledTimes(1);
  });

  test("an incomplete subscription is requires_action; a dropped connection is unknown, not retried", () => {
    expect(cloudIntroRenewalOutcome({ subscription: { id: "sub_1", status: "incomplete" } }).status).toBe("requires_action");
    expect(cloudIntroRenewalOutcome({ error: stripeError("StripeConnectionError") }).status).toBe("unknown");
    expect(cloudIntroRenewalOutcome({ error: new Error("socket hang up") }).status).toBe("unknown");
  });

  test("unticked: a pass without the renew choice is never charged", async () => {
    const table = passTable([row({ renewOnPlus: false, paymentMethodId: null })]);
    const stripe = fakeStripe();
    expect((await runCloudIntroRenewals(renewalDeps(table, stripe))).considered).toBe(0);
    expect(stripe.create).not.toHaveBeenCalled();
  });

  test("flag off: nothing is read, claimed or charged, even with the pass flag on", async () => {
    const table = passTable([row()]);
    const stripe = fakeStripe();
    const listDue = mock(table.renewals.listDue);
    const result = await runCloudIntroRenewals(renewalDeps(table, stripe, { env: PASS_ON, store: { ...table.renewals, listDue } }));
    expect(result.skipped).toBe(true);
    expect(listDue).not.toHaveBeenCalled();
    expect(stripe.create).not.toHaveBeenCalled();
    expect(table.byId.get("cs_pass_1")!.renewalStatus).toBeNull();
  });

  test("not before day 30, not after the pass ends", async () => {
    const stripe = fakeStripe();
    const table = passTable([row()]);
    await runCloudIntroRenewals(renewalDeps(table, stripe, { now: onDay(30, -1) }));
    await runCloudIntroRenewals(renewalDeps(table, stripe, { now: ENDS }));
    expect(stripe.create).not.toHaveBeenCalled();
  });

  test("a buyer who already has a plan is not charged; a failed plan read waits for the next run", async () => {
    const table = passTable([row()]);
    const stripe = fakeStripe();
    await runCloudIntroRenewals(renewalDeps(table, stripe, { hasPersonalPlan: async () => { throw new Error("down"); } }));
    expect(table.byId.get("cs_pass_1")!.renewalStatus).toBeNull();
    const result = await runCloudIntroRenewals(renewalDeps(table, stripe, { hasPersonalPlan: async () => true }));
    expect(result.hadPlan).toBe(1);
    expect(table.byId.get("cs_pass_1")!.renewalStatus).toBe("skipped_has_plan");
    expect(stripe.create).not.toHaveBeenCalled();
  });
});

describe("what the statements say about the charge", () => {
  const links = cloudIntroStatementLinks("https://cmux.com");
  const textFor = (pass: CloudIntroStatementRow, day: 21 | 27 | 30, chargeEnabled: boolean, now = onDay(day)) => {
    const renewal = cloudIntroRenewalView(pass, chargeEnabled, now);
    if (!renewal) throw new Error("held");
    return cloudIntroStatementText(buildCloudIntroStatement({ pass, day, usage: READ, now, renewal }), cloudIntroStatementCopy, links);
  };

  test("day 27, renew ticked, charge on: the date, the amount and the turn-off link", () => {
    const text = textFor(row(), 27, true);
    const line = `On November 30, 2026 your card will be charged $${GO_PRICING_USD.month.billedAmount} for Plus, monthly. Turn this off: https://cmux.com/dashboard/billing?pass=renew`;
    expect(text.lines).toContain(line);
    expect(text.turnOff).toEqual({ label: en.emails.cloudPassStatement.turnOff, href: "https://cmux.com/dashboard/billing?pass=renew" });
  });

  test("day 27 for everyone else: you will not be charged", () => {
    const text = textFor(row({ renewOnPlus: false, paymentMethodId: null }), 27, true);
    expect(text.lines).toContain("You will not be charged.");
    expect(text.turnOff).toBeNull();
  });

  test("charge flag off: renew buyers are told the choice is saved and we ask first", () => {
    const text = textFor(row(), 27, false);
    expect(text.lines).toContain(en.emails.cloudPassStatement.renewSaved);
    expect(text.lines.join(" ")).not.toContain("will be charged");
  });

  test("day 30 after a failed or held-for-action charge: says so, and asks Plus, Pro or not now", () => {
    for (const renewalStatus of ["failed", "requires_action"] as const) {
      const text = textFor(row({ renewalStatus }), 30, true);
      expect(text.lines).toContain(en.emails.cloudPassStatement.chargeFailed);
      expect(text.choices.map((choice) => choice.key)).toEqual(["plus", "pro", "not_now"]);
    }
  });

  test("day 30 after the charge went through: on Plus, no ask", () => {
    const text = textFor(row({ renewalStatus: "succeeded" }), 30, true);
    expect(text.lines.join(" ")).toContain("You are on Plus now");
    expect(text.choices).toEqual([]);
  });

  test("a charge in flight or of unknown outcome holds the statement", () => {
    expect(cloudIntroRenewalView(row({ renewalStatus: "started" }), true, onDay(30))).toBeNull();
    expect(cloudIntroRenewalView(row({ renewalStatus: "unknown" }), true, onDay(30))).toBeNull();
  });

  test("the dashboard shows the stored statement with the choice as it is now", () => {
    const pass = row();
    const stored = buildCloudIntroStatement({ pass, day: 27, usage: READ, now: onDay(27), renewal: "will_charge" });
    const turnedOff = withCurrentRenewal(stored, cloudIntroRenewalView({ ...pass, renewOnPlus: false, paymentMethodId: null }, true, onDay(28)), STARTED);
    expect(turnedOff.renewal).toBe("none");
    expect(turnedOff.chargeOn).toBeNull();
  });

  test("the cron order on day 30: charge first, then a statement that names the outcome", async () => {
    for (const [behavior, expected] of [
      [async () => ({ id: "sub_1", status: "active" }), "You are on Plus now"],
      [async () => { throw stripeError("StripeCardError", { code: "card_declined" }); }, en.emails.cloudPassStatement.chargeFailed],
    ] as const) {
      const table = passTable([row()]);
      const now = onDay(30, 60_000);
      await runCloudIntroRenewals(renewalDeps(table, fakeStripe(behavior), { now }));
      const sendEmail = mock(async (_payload: { text: string }, _options: { idempotencyKey: string }) => ({ error: null }));
      await runCloudIntroStatements({
        env: CHARGE_ON,
        now,
        store: table.statements,
        readUsage: async () => READ,
        recipientEmail: async () => "buyer@example.com",
        sendEmail: sendEmail as never,
        fromEmail: "pro@cmux.com",
        replyTo: "pro@cmux.com",
        origin: "https://cmux.com",
      });
      expect(sendEmail).toHaveBeenCalledTimes(1);
      expect(sendEmail.mock.calls[0]![0].text).toContain(expected);
    }
  });

  test("an unknown charge outcome sends no day-30 statement", async () => {
    const table = passTable([row({ renewalStatus: "unknown" })]);
    const sendEmail = mock(async () => ({ error: null }));
    await runCloudIntroStatements({
      env: CHARGE_ON,
      now: onDay(30),
      store: table.statements,
      readUsage: async () => READ,
      recipientEmail: async () => "buyer@example.com",
      sendEmail,
      fromEmail: "pro@cmux.com",
      replyTo: "pro@cmux.com",
      origin: "https://cmux.com",
    });
    expect(sendEmail).not.toHaveBeenCalled();
    expect(table.byId.get("cs_pass_1")!.statements["30"]).toBeUndefined();
  });
});

describe("turning the Plus charge off", () => {
  const write = (id: string | null) => Promise.resolve(id);

  test("turnOffRow: off with the card to detach, already off, too late, no pass", async () => {
    const now = onDay(20);
    expect(await turnOffRow({ renewOnPlus: true, paymentMethodId: "pm_1", renewalStatus: null }, now, write)).toEqual({ status: "off", paymentMethodId: "pm_1" });
    expect(await turnOffRow({ renewOnPlus: false, paymentMethodId: null, renewalStatus: null }, now, write)).toEqual({ status: "already_off" });
    for (const renewalStatus of ["started", "succeeded", "unknown"]) {
      expect(await turnOffRow({ renewOnPlus: true, paymentMethodId: "pm_1", renewalStatus }, now, write)).toEqual({ status: "too_late" });
    }
    // After a failed charge the card can still be removed.
    expect(await turnOffRow({ renewOnPlus: true, paymentMethodId: "pm_1", renewalStatus: "failed" }, now, write)).toEqual({ status: "off", paymentMethodId: "pm_1" });
    expect(await turnOffRow(null, now, write)).toEqual({ status: "no_pass" });
  });

  function route(result: CloudIntroRenewTurnOff, options: { user?: { id: string } | null; env?: Record<string, string | undefined> } = {}) {
    const turnOff = mock(async (_stackUserId: string, _now: Date) => result);
    const detach = mock(async (id: string) => ({ id }));
    const call = (init: { origin?: string; query?: string } = {}) => cloudIntroRenewResponse(
      new NextRequest(`https://cmux.test/api/billing/cloud-pass/renew${init.query ?? ""}`, {
        method: "POST",
        headers: init.origin ? { origin: init.origin } : {},
      }),
      { stackServerApp: async () => ({ getUser: async () => (options.user === undefined ? { id: "user_1" } : options.user) }) },
      {
        env: options.env ?? PASS_ON,
        store: { turnOff },
        stripe: () => ({ paymentMethods: { detach } }) as never,
      },
    );
    return { call, turnOff, detach };
  }

  test("404 with the pass flag off, 403 from a foreign origin", async () => {
    const r = route({ status: "off", paymentMethodId: "pm_1" }, { env: { NODE_ENV: "production", VERCEL_ENV: "production" } });
    expect((await r.call()).status).toBe(404);
    const s = route({ status: "off", paymentMethodId: "pm_1" });
    expect((await s.call({ origin: "https://evil.test" })).status).toBe(403);
    expect(s.turnOff).not.toHaveBeenCalled();
  });

  test("signed out goes to sign-in and changes nothing", async () => {
    const r = route({ status: "off", paymentMethodId: "pm_1" }, { user: null });
    const response = await r.call();
    expect(response.status).toBe(303);
    expect(response.headers.get("location")).toContain("/handler/sign-in");
    expect(r.turnOff).not.toHaveBeenCalled();
  });

  test("turns the charge off and detaches the saved card", async () => {
    const r = route({ status: "off", paymentMethodId: "pm_1" });
    const response = await r.call({ origin: "https://cmux.test" });
    expect(response.status).toBe(303);
    expect(response.headers.get("location")).toBe("https://cmux.test/dashboard/billing?pass=renew-off");
    expect(r.turnOff.mock.calls[0]![0]).toBe("user_1");
    expect(r.detach.mock.calls).toEqual([["pm_1"]]);
  });

  test("too late once the charge went through; JSON on request", async () => {
    const r = route({ status: "too_late" });
    const response = await r.call({ query: "?format=json" });
    expect(await response.json()).toEqual({ status: "too_late", url: "https://cmux.test/dashboard/billing?pass=renew-too-late" });
    expect(r.detach).not.toHaveBeenCalled();
  });

  test("a failed detach still answers turned off", async () => {
    const r = route({ status: "off", paymentMethodId: "pm_1" });
    r.detach.mockImplementation((async () => { throw new Error("gone"); }) as never);
    const response = await r.call({ query: "?format=json" });
    expect((await response.json()).status).toBe("off");
    expect(captureBillingError).toHaveBeenCalled();
  });
});
