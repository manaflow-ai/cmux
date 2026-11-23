import { describe, expect, mock, test } from "bun:test";
import { NextRequest } from "next/server";

import {
  CLOUD_INTRO_PLAN_ID,
  cloudIntroRefusal,
  cloudIntroTerm,
  cloudIntroUtcDayStart,
  isCloudIntroEnabled,
  withCloudIntroGrant,
  withoutEndedCloudIntro,
  type CloudIntroTerm,
} from "../services/billing/cloudIntro";
import { createDrizzleCloudIntroAccountFacts, type CloudIntroAccountFacts } from "../services/billing/cloudIntroPasses";
import {
  CLOUD_TASTE_AWAKE_HOURS,
  CLOUD_TASTE_BILLING_COPY,
  CLOUD_TASTE_DAILY_CAP,
  CLOUD_TASTE_INCLUDED,
  CLOUD_TASTE_PLAN_ID,
  CLOUD_TASTE_TERM_DAYS,
  cloudTasteBillingCode,
  cloudTasteRefusal,
  cloudTasteRefusalBillingCode,
  cloudTasteTerm,
  type CloudTasteFacts,
} from "../services/billing/cloudTaste";
import {
  decide,
  grantCloudTaste,
  withCloudTasteGrant,
  type CloudTasteDependencies,
  type CloudTasteGrant,
  type CloudTasteStore,
} from "../services/billing/cloudTasteGrants";
import { cloudTasteResponse, type CloudTasteRouteContext } from "../services/billing/cloudTasteRoute";
import { isPaidPlanId } from "../services/billing/pro";
import { emptyBillingDbRows, stubBillingDb } from "./helpers/billing-team-fixtures";

const ON = { CMUX_CLOUD_INTRO: "1" };
const OFF = { NODE_ENV: "production", VERCEL_ENV: "production" };
const NOW = new Date("2026-11-23T12:00:00.000Z");
const WEEK_END = new Date("2026-11-30T12:00:00.000Z");

const eligible: CloudTasteFacts = {
  hadPaidPlan: false,
  isTeamSeat: false,
  hadPass: false,
  hadTaste: false,
  teamHadTaste: false,
  grantedToday: 0,
};

type TasteRow = CloudTasteGrant & { stackTeamIds: string[] };

/** The store contract of cloudTasteGrants.ts, in memory; `passes` are users granted a $1 pass. */
function memoryTasteStore() {
  const rows = new Map<string, TasteRow>();
  const passes = new Set<string>();
  const grant = mock<CloudTasteStore["grant"]>(async (input, judge) => {
    const own = rows.get(input.stackUserId) ?? null;
    const dayStart = cloudIntroUtcDayStart(input.now).getTime();
    const refusal = judge({
      hadPass: passes.has(input.stackUserId),
      hadTaste: own !== null,
      teamHadTaste: [...rows.values()].some((row) =>
        row.stackUserId !== input.stackUserId && row.stackTeamIds.some((id) => input.stackTeamIds.includes(id))),
      grantedToday: [...rows.values()].filter((row) => row.startedAt.getTime() >= dayStart).length,
    });
    const existing = own ? { stackUserId: own.stackUserId, startedAt: own.startedAt, endsAt: own.endsAt } : null;
    const decision = decide(existing, input, refusal);
    if (decision.status === "granted" && !decision.existing) {
      rows.set(input.stackUserId, { ...decision.grant, stackTeamIds: [...input.stackTeamIds] });
    }
    return { existing, decision };
  });
  return { rows, passes, store: { grant } satisfies CloudTasteStore, grant };
}

const noHistory: CloudIntroAccountFacts = { hadPaidPlan: false, isTeamSeat: false, stackTeamIds: [] };

function harness() {
  const memory = memoryTasteStore();
  const metadata = new Map<string, Record<string, unknown>>();
  const accounts = new Map<string, CloudIntroAccountFacts>();
  let now = NOW;
  const written: string[] = [];
  const writeGrant = mock(async (userId: string, term: CloudIntroTerm) => {
    const next = withCloudTasteGrant(metadata.get(userId) ?? {}, term);
    if (!next) return false;
    metadata.set(userId, next);
    written.push(userId);
    return true;
  });
  const dependencies: CloudTasteDependencies = {
    now: () => now,
    store: memory.store,
    accountFacts: async (user) => accounts.get(user.id) ?? noHistory,
    writeGrant,
  };
  return {
    ...memory,
    metadata,
    written,
    accounts,
    writeGrant,
    dependencies,
    setNow(next: Date) { now = next; },
    grantTo: (id: string) => grantCloudTaste({ id }, dependencies),
  };
}

describe("cmux Cloud free week rules", () => {
  test("seven days, 100 a day, one Chief with 1,200 machine-minutes (10 awake hours on 2 vCPU)", () => {
    expect(CLOUD_TASTE_PLAN_ID).toBe("next_taste");
    expect(CLOUD_TASTE_TERM_DAYS).toBe(7);
    expect(CLOUD_TASTE_DAILY_CAP).toBe(100);
    expect(CLOUD_TASTE_INCLUDED).toEqual({ chiefs: 1, chiefVcpu: 2, machineMinutes: 1_200 });
    expect(CLOUD_TASTE_AWAKE_HOURS).toBe(10);
    expect(cloudTasteTerm(NOW)).toEqual({ startedAt: NOW, endsAt: WEEK_END });
  });

  test("refuses each rule, permanent reasons before the daily cap", () => {
    expect(cloudTasteRefusal(eligible)).toBeNull();
    expect(cloudTasteRefusal({ ...eligible, hadPaidPlan: true })).toBe("had_paid_plan");
    expect(cloudTasteRefusal({ ...eligible, hadPass: true })).toBe("already_had_pass");
    expect(cloudTasteRefusal({ ...eligible, hadTaste: true })).toBe("already_had_taste");
    expect(cloudTasteRefusal({ ...eligible, isTeamSeat: true })).toBe("team_seat");
    expect(cloudTasteRefusal({ ...eligible, teamHadTaste: true })).toBe("team_already_had_taste");
    expect(cloudTasteRefusal({ ...eligible, grantedToday: 99 })).toBeNull();
    expect(cloudTasteRefusal({ ...eligible, grantedToday: 100 })).toBe("daily_cap_reached");
    expect(cloudTasteRefusal({ ...eligible, hadPass: true, grantedToday: 100 })).toBe("already_had_pass");
  });

  test("answers sold out today or unavailable", () => {
    expect(cloudTasteRefusalBillingCode("daily_cap_reached")).toBe("taste_sold_out_today");
    for (const refusal of ["had_paid_plan", "already_had_pass", "already_had_taste", "team_seat", "team_already_had_taste"] as const) {
      expect(cloudTasteRefusalBillingCode(refusal)).toBe("taste_unavailable");
    }
    expect(cloudTasteBillingCode("taste_unavailable")).toBe("taste_unavailable");
    expect(cloudTasteBillingCode("intro_unavailable")).toBeNull();
    expect(cloudTasteBillingCode("toString")).toBeNull();
  });

  test("is behind the pass's flag", () => {
    expect(isCloudIntroEnabled()).toBe(false);
    expect(isCloudIntroEnabled(OFF)).toBe(false);
    expect(isCloudIntroEnabled(ON)).toBe(true);
  });
});

describe("cmux Cloud free week grant", () => {
  test("grants a new individual seven days and writes only the three keys", async () => {
    const h = harness();
    h.metadata.set("user_1", { cmuxPlan: "free", cmuxVmPlan: "free" });
    const decision = await h.grantTo("user_1");
    expect(decision).toEqual({
      status: "granted",
      existing: false,
      grant: { stackUserId: "user_1", startedAt: NOW, endsAt: WEEK_END },
    });
    expect(h.metadata.get("user_1")).toEqual({
      cmuxPlan: "free",
      cmuxVmPlan: "free",
      cmuxNextPlan: "next_taste",
      cmuxNextPlanStartedAt: "2026-11-23T12:00:00.000Z",
      cmuxNextPlanEndsAt: "2026-11-30T12:00:00.000Z",
    });
    expect(h.rows.size).toBe(1);
  });

  test("a repeat call while the week runs answers the same grant and adds no row", async () => {
    const h = harness();
    await h.grantTo("user_1");
    h.setNow(new Date("2026-11-25T08:00:00.000Z"));
    const again = await h.grantTo("user_1");
    expect(again).toEqual({
      status: "granted",
      existing: true,
      grant: { stackUserId: "user_1", startedAt: NOW, endsAt: WEEK_END },
    });
    expect(h.rows.size).toBe(1);
    // The metadata already says it: nothing is written the second time.
    expect(h.writeGrant).toHaveBeenCalledTimes(2);
    expect(h.written).toEqual(["user_1"]);
  });

  test("after the week ends it is never granted again", async () => {
    const h = harness();
    await h.grantTo("user_1");
    h.setNow(WEEK_END);
    expect(await h.grantTo("user_1")).toEqual({ status: "refused", refusal: "already_had_taste" });
    expect(h.writeGrant).toHaveBeenCalledTimes(1);
  });

  test("a second person on the same team is refused", async () => {
    const h = harness();
    h.accounts.set("user_1", { ...noHistory, stackTeamIds: ["team_1"] });
    h.accounts.set("user_2", { ...noHistory, stackTeamIds: ["team_2", "team_1"] });
    h.accounts.set("user_3", { ...noHistory, stackTeamIds: ["team_3"] });
    expect((await h.grantTo("user_1")).status).toBe("granted");
    expect(await h.grantTo("user_2")).toEqual({ status: "refused", refusal: "team_already_had_taste" });
    expect((await h.grantTo("user_3")).status).toBe("granted");
    expect(h.metadata.has("user_2")).toBe(false);
  });

  test("a person who had the $1 pass is refused", async () => {
    const h = harness();
    h.passes.add("user_1");
    expect(await h.grantTo("user_1")).toEqual({ status: "refused", refusal: "already_had_pass" });
    expect(h.rows.size).toBe(0);
    expect(h.writeGrant).not.toHaveBeenCalled();
  });

  test("a person who had a paid plan is refused", async () => {
    const h = harness();
    h.accounts.set("user_1", { ...noHistory, hadPaidPlan: true });
    expect(await h.grantTo("user_1")).toEqual({ status: "refused", refusal: "had_paid_plan" });
    expect(h.writeGrant).not.toHaveBeenCalled();
  });

  test("a Team seat is refused", async () => {
    const h = harness();
    h.accounts.set("user_1", { ...noHistory, isTeamSeat: true, stackTeamIds: ["team_1"] });
    expect(await h.grantTo("user_1")).toEqual({ status: "refused", refusal: "team_seat" });
    expect(h.rows.size).toBe(0);
  });

  test("grants at most 100 a UTC day, and again after midnight", async () => {
    const h = harness();
    for (let i = 0; i < 100; i += 1) expect((await h.grantTo(`user_${i}`)).status).toBe("granted");
    expect(await h.grantTo("user_late")).toEqual({ status: "refused", refusal: "daily_cap_reached" });
    expect(h.rows.size).toBe(100);
    h.setNow(new Date("2026-11-24T00:00:00.000Z"));
    expect((await h.grantTo("user_late")).status).toBe("granted");
  });

  test("a pass after a free week is allowed and replaces its keys; the free week never overwrites a pass", async () => {
    const h = harness();
    await h.grantTo("user_1");
    const taste = h.metadata.get("user_1")!;
    // The pass's account facts read Stripe, the App Store and cmuxPlan/cmuxVmPlan, never cmuxNextPlan.
    expect(isPaidPlanId(CLOUD_TASTE_PLAN_ID)).toBe(false);
    const accountFacts = createDrizzleCloudIntroAccountFacts(() => stubBillingDb(() => emptyBillingDbRows()) as never);
    const account = await accountFacts({ id: "user_1", clientReadOnlyMetadata: taste });
    expect(account.hadPaidPlan).toBe(false);
    const passFacts = {
      ...account, hadPass: false, teamHadPass: false, grantedToday: 0, grantedTotal: 0, cardAttempts: 0,
    };
    expect(cloudIntroRefusal(passFacts, "checkout")).toBeNull();
    expect(cloudIntroRefusal({ ...passFacts, cardFunding: "credit" }, "payment")).toBeNull();

    const passTerm = cloudIntroTerm(new Date("2026-11-24T09:00:00.000Z"));
    const withPass = withCloudIntroGrant(taste, passTerm)!;
    expect(withPass).toMatchObject({
      cmuxNextPlan: CLOUD_INTRO_PLAN_ID,
      cmuxNextPlanStartedAt: "2026-11-24T09:00:00.000Z",
      cmuxNextPlanEndsAt: "2026-12-24T09:00:00.000Z",
    });
    // A late repeat of the free week (or a race with the pass's write) leaves the pass alone.
    expect(withCloudTasteGrant(withPass, cloudTasteTerm(NOW))).toBeNull();
    h.metadata.set("user_1", withPass);
    expect((await h.grantTo("user_1")).status).toBe("granted");
    expect(h.metadata.get("user_1")).toEqual(withPass);
    // Once the pass is recorded, a new free week is refused.
    h.passes.add("user_2");
    expect(await h.grantTo("user_2")).toEqual({ status: "refused", refusal: "already_had_pass" });
  });

  test("the end at read time removes the free week's three keys and nothing else", () => {
    const granted = withCloudTasteGrant({ cmuxPlan: "free", cmuxVmPlan: "pro" }, cloudTasteTerm(NOW))!;
    expect(withoutEndedCloudIntro(granted, new Date(WEEK_END.getTime() - 1))).toBeNull();
    expect(withoutEndedCloudIntro(granted, WEEK_END)).toEqual({ cmuxPlan: "free", cmuxVmPlan: "pro" });
    expect(withoutEndedCloudIntro({ cmuxNextPlan: "next_taste", cmuxNextPlanEndsAt: "garbage" }, NOW)).toEqual({});
    // Any other cmuxNextPlan is not ours to end.
    expect(withoutEndedCloudIntro({ cmuxNextPlan: "next_other", cmuxNextPlanEndsAt: "2020-01-01T00:00:00.000Z" }, NOW)).toBeNull();
  });
});

describe("cmux Cloud free week route", () => {
  function routeHarness(user: { id: string; isAnonymous?: boolean; clientReadOnlyMetadata?: unknown } | null) {
    const h = harness();
    const getUser = mock(async () => user);
    const context: CloudTasteRouteContext = { stackServerApp: async () => ({ getUser }) };
    const post = (env: Record<string, string | undefined>, query = "", init: { origin?: string; body?: string } = {}) =>
      cloudTasteResponse(
        new NextRequest(`https://cmux.test/api/billing/cloud-taste${query}`, {
          method: "POST",
          headers: {
            "content-type": "application/x-www-form-urlencoded",
            ...(init.origin ? { origin: init.origin } : {}),
          },
          body: init.body ?? "intro=b",
        }),
        context,
        { ...h.dependencies, env },
      );
    return { ...h, getUser, post };
  }

  test("with the flag off it answers 404, reads no user and grants nothing", async () => {
    const r = routeHarness({ id: "user_1" });
    const response = await r.post(OFF);
    expect(response.status).toBe(404);
    expect(r.getUser).not.toHaveBeenCalled();
    expect(r.grant).not.toHaveBeenCalled();
    expect(r.writeGrant).not.toHaveBeenCalled();
    expect(r.metadata.size).toBe(0);

    const { POST } = await import("../app/api/billing/cloud-taste/route");
    const live = await POST(new NextRequest("https://cmux.test/api/billing/cloud-taste", { method: "POST" }));
    expect(live.status).toBe(404);
  });

  test("grants and sends a browser to Plan & billing with a 303; a repeat answers the same grant", async () => {
    const r = routeHarness({ id: "user_1" });
    const response = await r.post(ON);
    expect(response.status).toBe(303);
    expect(response.headers.get("location")).toBe("https://cmux.test/dashboard/billing?welcome=taste");
    const again = await r.post(ON, "?format=json");
    expect(await again.json()).toEqual({
      status: "granted",
      startedAt: "2026-11-23T12:00:00.000Z",
      endsAt: "2026-11-30T12:00:00.000Z",
      url: "https://cmux.test/dashboard/billing?welcome=taste",
    });
    expect(r.rows.size).toBe(1);
  });

  test("refusals go to /pricing with the free week's codes", async () => {
    const r = routeHarness({ id: "user_1" });
    r.accounts.set("user_1", { ...noHistory, isTeamSeat: true });
    expect((await r.post(ON)).headers.get("location")).toBe("https://cmux.test/pricing?billing=taste_unavailable");

    const full = routeHarness({ id: "user_late" });
    for (let i = 0; i < 100; i += 1) await full.grantTo(`user_${i}`);
    const response = await full.post(ON, "?format=json");
    expect(await response.json()).toMatchObject({ status: "refused", code: "taste_sold_out_today" });
  });

  test("signed out goes to sign-in and back to the same pricing layout", async () => {
    const r = routeHarness(null);
    const response = await r.post(ON);
    expect(response.status).toBe(303);
    const location = new URL(response.headers.get("location")!);
    expect(location.pathname).toBe("/handler/sign-in");
    const afterSignIn = new URL(location.searchParams.get("after_auth_return_to")!, "https://cmux.test");
    expect(afterSignIn.searchParams.get("after_auth_return_to")).toBe("/next/pricing?intro=b");
    expect(r.grant).not.toHaveBeenCalled();
  });

  test("a cross-site post grants nothing", async () => {
    const r = routeHarness({ id: "user_1" });
    const response = await r.post(ON, "", { origin: "https://evil.test" });
    expect(response.status).toBe(403);
    expect(r.grant).not.toHaveBeenCalled();
    expect((await r.post(ON, "", { origin: "https://cmux.test" })).status).toBe(303);
  });
});

describe("cmux Cloud free week copy", () => {
  test("the refusal copy names no vendor, cost or margin", () => {
    for (const copy of Object.values(CLOUD_TASTE_BILLING_COPY)) {
      expect(copy).not.toMatch(/stripe|freestyle|e2b|daytona|morph|margin|\bcost|\$/i);
    }
  });
});
