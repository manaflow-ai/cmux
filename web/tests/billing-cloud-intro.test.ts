import { describe, expect, test } from "bun:test";

import {
  CLOUD_INTRO_BILLING_COPY,
  CLOUD_INTRO_DAILY_CAP,
  CLOUD_INTRO_INCLUDED,
  CLOUD_INTRO_MAX_CARD_ATTEMPTS,
  CLOUD_INTRO_TOTAL_CAP,
  cloudIntroEndsAt,
  cloudIntroRefusal,
  cloudIntroRefusalBillingCode,
  cloudIntroRenewChosen,
  cloudIntroTerm,
  cloudIntroUtcDayStart,
  isCloudIntroEnabled,
  withCloudIntroGrant,
  withoutEndedCloudIntro,
  type CloudIntroFacts,
} from "../services/billing/cloudIntro";

const eligible: CloudIntroFacts = {
  hadPaidPlan: false,
  hadPass: false,
  isTeamSeat: false,
  teamHadPass: false,
  grantedToday: 0,
  grantedTotal: 0,
  cardAttempts: 0,
  cardFunding: "credit",
  cardFingerprintUsed: false,
};

describe("cmux Cloud $1 pass flag", () => {
  test("is off under test, and in Vercel production, unless CMUX_CLOUD_INTRO=1", () => {
    expect(isCloudIntroEnabled({ NODE_ENV: "test" })).toBe(false);
    expect(isCloudIntroEnabled({})).toBe(false);
    expect(isCloudIntroEnabled({ NODE_ENV: "production", VERCEL_ENV: "production" })).toBe(false);
    expect(isCloudIntroEnabled({ NODE_ENV: "production", VERCEL_ENV: "production", CMUX_CLOUD_INTRO: "0" })).toBe(false);
    expect(isCloudIntroEnabled({ NODE_ENV: "production", VERCEL_ENV: "production", CMUX_CLOUD_INTRO: "1" })).toBe(true);
    expect(isCloudIntroEnabled({ NODE_ENV: "test", CMUX_CLOUD_INTRO: "1" })).toBe(true);
  });

  test("is on in local dev and preview deployments", () => {
    expect(isCloudIntroEnabled({ NODE_ENV: "development" })).toBe(true);
    expect(isCloudIntroEnabled({ NODE_ENV: "production", VERCEL_ENV: "preview" })).toBe(true);
  });

  test("the process default under bun test is off", () => {
    expect(isCloudIntroEnabled()).toBe(false);
  });
});

describe("cmux Cloud $1 pass eligibility", () => {
  test("an account that never paid and never had a pass may buy it", () => {
    expect(cloudIntroRefusal(eligible, "checkout")).toBeNull();
    expect(cloudIntroRefusal(eligible, "payment")).toBeNull();
  });

  test("refuses each once-per rule with its own reason", () => {
    expect(cloudIntroRefusal({ ...eligible, hadPaidPlan: true }, "checkout")).toBe("had_paid_plan");
    expect(cloudIntroRefusal({ ...eligible, hadPass: true }, "checkout")).toBe("already_had_pass");
    expect(cloudIntroRefusal({ ...eligible, isTeamSeat: true }, "checkout")).toBe("team_seat");
    expect(cloudIntroRefusal({ ...eligible, teamHadPass: true }, "checkout")).toBe("team_already_had_pass");
  });

  test("refuses a prepaid card and a card fingerprint already used, at payment only", () => {
    expect(cloudIntroRefusal({ ...eligible, cardFunding: "prepaid" }, "payment")).toBe("prepaid_card");
    expect(cloudIntroRefusal({ ...eligible, cardFingerprintUsed: true }, "payment")).toBe("card_already_used");
    expect(cloudIntroRefusal({ ...eligible, cardFunding: "prepaid" }, "checkout")).toBeNull();
  });

  test("allows three card attempts per account, counted at checkout", () => {
    expect(CLOUD_INTRO_MAX_CARD_ATTEMPTS).toBe(3);
    expect(cloudIntroRefusal({ ...eligible, cardAttempts: 2 }, "checkout")).toBeNull();
    expect(cloudIntroRefusal({ ...eligible, cardAttempts: 3 }, "checkout")).toBe("attempts_exhausted");
    // The paid checkout itself is one of the attempts; payment does not recount.
    expect(cloudIntroRefusal({ ...eligible, cardAttempts: 3 }, "payment")).toBeNull();
  });

  test("caps passes at 100 per UTC day and 1,000 in total", () => {
    expect(CLOUD_INTRO_DAILY_CAP).toBe(100);
    expect(CLOUD_INTRO_TOTAL_CAP).toBe(1_000);
    expect(cloudIntroRefusal({ ...eligible, grantedToday: 99 }, "checkout")).toBeNull();
    expect(cloudIntroRefusal({ ...eligible, grantedToday: 100 }, "checkout")).toBe("daily_cap_reached");
    expect(cloudIntroRefusal({ ...eligible, grantedTotal: 999 }, "payment")).toBeNull();
    expect(cloudIntroRefusal({ ...eligible, grantedTotal: 1_000, grantedToday: 100 }, "payment")).toBe("total_cap_reached");
  });

  test("names a permanent reason before a cap, so nobody is told to come back for a pass they cannot get", () => {
    expect(cloudIntroRefusal({ ...eligible, hadPaidPlan: true, grantedToday: 100 }, "checkout")).toBe("had_paid_plan");
  });

  test("answers sold out today, sold out, or unavailable", () => {
    expect(cloudIntroRefusalBillingCode("daily_cap_reached")).toBe("intro_sold_out_today");
    expect(cloudIntroRefusalBillingCode("total_cap_reached")).toBe("intro_sold_out");
    expect(cloudIntroRefusalBillingCode("had_paid_plan")).toBe("intro_unavailable");
    expect(CLOUD_INTRO_BILLING_COPY.intro_sold_out_today).toContain("Today's $1 passes are gone");
    expect(CLOUD_INTRO_BILLING_COPY.intro_sold_out).toContain("The first $1 passes are gone");
  });

  test("user-facing constants carry the included usage", () => {
    expect(CLOUD_INTRO_INCLUDED).toEqual({ chiefAwakeHours: 100, machineMinutes: 3_000, concurrentMachines: 5 });
    for (const copy of Object.values(CLOUD_INTRO_BILLING_COPY)) {
      expect(copy).not.toMatch(/stripe|freestyle|e2b|daytona|morph/i);
    }
  });

  test("the daily cap resets at UTC midnight", () => {
    expect(cloudIntroUtcDayStart(new Date("2026-11-23T23:59:59.000-05:00")).toISOString()).toBe("2026-11-24T00:00:00.000Z");
    expect(cloudIntroUtcDayStart(new Date("2026-11-23T00:00:00.000Z")).toISOString()).toBe("2026-11-23T00:00:00.000Z");
  });

  test("the renew choice is off unless the request turns it on", () => {
    expect(cloudIntroRenewChosen(null)).toBe(false);
    expect(cloudIntroRenewChosen("")).toBe(false);
    expect(cloudIntroRenewChosen("0")).toBe(false);
    expect(cloudIntroRenewChosen("1")).toBe(true);
  });
});

describe("cmux Cloud $1 pass metadata", () => {
  const term = cloudIntroTerm(new Date("2026-11-23T12:00:00.000Z"));

  test("runs 30 days and writes only the three pass keys", () => {
    expect(term.endsAt.toISOString()).toBe("2026-12-23T12:00:00.000Z");
    const next = withCloudIntroGrant({ cmuxPlan: "free", cmuxVmPlan: "pro", other: 1 }, term);
    expect(next).toEqual({
      cmuxPlan: "free",
      cmuxVmPlan: "pro",
      other: 1,
      cmuxNextPlan: "next_intro",
      cmuxNextPlanStartedAt: "2026-11-23T12:00:00.000Z",
      cmuxNextPlanEndsAt: "2026-12-23T12:00:00.000Z",
    });
    expect(withCloudIntroGrant(next, term)).toBeNull();
  });

  test("removes an ended pass and nothing else; leaves a running pass alone", () => {
    const granted = withCloudIntroGrant({ cmuxPlan: "pro" }, term)!;
    expect(withoutEndedCloudIntro(granted, new Date("2026-12-23T11:59:59.000Z"))).toBeNull();
    expect(withoutEndedCloudIntro(granted, new Date("2026-12-23T12:00:00.000Z"))).toEqual({ cmuxPlan: "pro" });
    expect(withoutEndedCloudIntro({ cmuxPlan: "pro" }, new Date())).toBeNull();
    expect(cloudIntroEndsAt({ cmuxNextPlan: "next_intro", cmuxNextPlanEndsAt: "garbage" })?.getTime()).toBe(0);
  });
});
