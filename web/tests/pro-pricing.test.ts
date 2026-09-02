import { describe, expect, test } from "bun:test";

import enMessages from "../messages/en.json";
import jaMessages from "../messages/ja.json";
import {
  LEGACY_PRICE_LOOKUP_KEYS,
  PRO_PRICING_USD,
  TEAM_PRICING_USD,
  proBillingInterval,
} from "../services/billing/plans";
import {
  PAID_MAX_ACTIVE_VMS_DEFAULT,
  PLAN_MACHINE_MEMORY_MB,
  VM_DISK_MB_DEFAULT,
  vcpusForMemoryMb,
} from "../services/vms/entitlements";

describe("pricing plans", () => {
  test("prices Pro at $50/mo and $480/yr with a 20% annual discount", () => {
    expect(PRO_PRICING_USD.month).toEqual({
      billedAmount: 50,
      monthlyEquivalent: 50,
      discountPercent: 0,
      lookupKey: "cmux-pro-monthly-50",
    });
    expect(PRO_PRICING_USD.year).toEqual({
      billedAmount: 480,
      monthlyEquivalent: 40,
      discountPercent: 20,
      lookupKey: "cmux-pro-yearly-480",
    });
    expect(PRO_PRICING_USD.year.billedAmount).toBe(
      PRO_PRICING_USD.month.billedAmount *
        12 *
        (1 - PRO_PRICING_USD.year.discountPercent / 100),
    );
    expect(PRO_PRICING_USD.year.monthlyEquivalent * 12).toBe(
      PRO_PRICING_USD.year.billedAmount,
    );
  });

  test("prices Team at $60/user/mo and $576/user/yr with a 20% annual discount", () => {
    expect(TEAM_PRICING_USD.month).toEqual({
      billedAmount: 60,
      monthlyEquivalent: 60,
      discountPercent: 0,
      lookupKey: "cmux-team-monthly-60",
    });
    expect(TEAM_PRICING_USD.year).toEqual({
      billedAmount: 576,
      monthlyEquivalent: 48,
      discountPercent: 20,
      lookupKey: "cmux-team-yearly-576",
    });
    expect(TEAM_PRICING_USD.year.billedAmount).toBe(
      TEAM_PRICING_USD.month.billedAmount *
        12 *
        (1 - TEAM_PRICING_USD.year.discountPercent / 100),
    );
    expect(TEAM_PRICING_USD.year.monthlyEquivalent * 12).toBe(
      TEAM_PRICING_USD.year.billedAmount,
    );
  });

  test("lookup keys carry their amount and never reuse a grandfathered key", () => {
    const current = [
      PRO_PRICING_USD.month,
      PRO_PRICING_USD.year,
      TEAM_PRICING_USD.month,
      TEAM_PRICING_USD.year,
    ];
    for (const price of current) {
      expect(price.lookupKey.endsWith(`-${price.billedAmount}`)).toBe(true);
      expect(LEGACY_PRICE_LOOKUP_KEYS).not.toContain(price.lookupKey);
    }
    expect(LEGACY_PRICE_LOOKUP_KEYS).toEqual([
      "cmux-pro-monthly",
      "cmux-pro-yearly",
      "cmux-pro-yearly-288",
      "cmux-team-monthly",
      "cmux-team-yearly-336",
    ]);
  });

  test("defaults unknown intervals to monthly", () => {
    expect(proBillingInterval("year")).toBe("year");
    expect(proBillingInterval("month")).toBe("month");
    expect(proBillingInterval("annual")).toBe("month");
    expect(proBillingInterval(null)).toBe("month");
  });
});

describe("pricing copy matches the plan policy", () => {
  // The public pricing copy states the machine allowance as prose, so pin the
  // numbers to the entitlement constants that enforce them. A price or spec
  // change that forgets the copy (or the copy that forgets the policy) fails
  // here instead of on the live page.
  const vcpus = vcpusForMemoryMb(PLAN_MACHINE_MEMORY_MB);
  const memoryGb = PLAN_MACHINE_MEMORY_MB / 1024;
  const diskGb = VM_DISK_MB_DEFAULT / 1024;

  test("the plan machine is 5 vCPU, 20 GB RAM, 200 GB disk, up to 50 machines", () => {
    expect(vcpus).toBe(5);
    expect(memoryGb).toBe(20);
    expect(diskGb).toBe(200);
    expect(PAID_MAX_ACTIVE_VMS_DEFAULT).toBe(50);
  });

  for (const [locale, messages] of [
    ["en", enMessages],
    ["ja", jaMessages],
  ] as const) {
    test(`${locale} pricing copy states the current prices and machine spec`, () => {
      const pricing = messages.pricing;
      const proFeatures = pricing.pro.features.join("\n");
      expect(proFeatures).toContain(`${PAID_MAX_ACTIVE_VMS_DEFAULT} `);
      expect(proFeatures).toContain(`${vcpus} vCPU`);
      expect(proFeatures).toContain(`${memoryGb} GB`);
      expect(proFeatures).toContain(`${diskGb} GB`);

      const vmRow = pricing.compare.rows.find((row) =>
        row.label.includes("Cloud VM") && row.pro === String(PAID_MAX_ACTIVE_VMS_DEFAULT),
      );
      expect(vmRow).toBeDefined();
      const sizeRow = pricing.compare.rows.find((row) => row.pro.includes(`${vcpus} vCPU`));
      expect(sizeRow?.pro).toContain(`${memoryGb} GB`);
      expect(sizeRow?.pro).toContain(`${diskGb} GB`);

      const faq = pricing.faq.items.map((item) => item.a).join("\n");
      expect(faq).toContain(`$${PRO_PRICING_USD.month.billedAmount}/`);
      expect(faq).toContain(`$${PRO_PRICING_USD.year.monthlyEquivalent}/`);
      expect(faq).toContain(`$${TEAM_PRICING_USD.month.billedAmount}/`);
      expect(faq).toContain(`$${TEAM_PRICING_USD.year.monthlyEquivalent}/`);
      for (const stale of ["$30/", "$24/", "$35/", "$28/"]) {
        expect(faq).not.toContain(stale);
      }
      expect(faq.toLowerCase()).not.toContain("unlimited active");
      expect(faq).not.toContain("無制限に利用");
    });
  }
});
