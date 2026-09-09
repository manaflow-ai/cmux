import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";

import enMessages from "../messages/en.json";
import jaMessages from "../messages/ja.json";
import { loadMessages } from "../i18n/messages";
import { locales } from "../i18n/routing";
import {
  LEGACY_PRICE_LOOKUP_KEYS,
  PRO_PRICING_USD,
  TEAM_PRICING_USD,
  proBillingInterval,
} from "../services/billing/plans";
import {
  PLAN_MACHINE_MEMORY_MB,
  PAID_MAX_ACTIVE_VMS_DEFAULT,
  vmResourceReservationForCreate,
  VM_DISK_MB_DEFAULT,
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

describe("VM defaults and pricing copy", () => {
  const memoryGb = PLAN_MACHINE_MEMORY_MB / 1024;
  const startingDiskGb = VM_DISK_MB_DEFAULT / 1024;
  test("VM creation defaults are separate from advertised shared plan resources", () => {
    expect(PAID_MAX_ACTIVE_VMS_DEFAULT).toBe(50);
    expect(memoryGb).toBe(8);
    expect(startingDiskGb).toBe(32);
  });

  test("a size-less plan reservation follows requested memory", () => {
    expect(vmResourceReservationForCreate({
      memoryMb: 32768,
      env: {},
    })).toEqual({
      vcpus: 8,
      memoryMb: 32768,
      diskMb: VM_DISK_MB_DEFAULT,
    });
  });

  test("a sized image reserves its complete provider shape", () => {
    expect(vmResourceReservationForCreate({
      imageSize: { cpu: 8, memoryMb: 32768, storageMb: 65536 },
    })).toEqual({ vcpus: 8, memoryMb: 32768, diskMb: 65536 });
  });

  test("a 4 GB image still reserves the documented 32 GB starting disk", () => {
    expect(vmResourceReservationForCreate({
      imageSize: { cpu: 1, memoryMb: 4096, storageMb: 16384 },
    })).toEqual({ vcpus: 1, memoryMb: 4096, diskMb: VM_DISK_MB_DEFAULT });
  });

  test("an image reservation includes an operator disk override", () => {
    expect(vmResourceReservationForCreate({
      imageSize: { cpu: 1, memoryMb: 4096, storageMb: 16384 },
      env: { CMUX_VM_DISK_MB: "65536" },
    })).toEqual({ vcpus: 1, memoryMb: 4096, diskMb: 65536 });
  });

  // These are the advertised plan limits, not the default shape of one VM.
  // Keep cards, comparison rows, FAQs, and native strings on the same policy.
  for (const [locale, messages, label, shared] of [
    ["en", enMessages, "Resources shared across all Cloud VMs", "shared across all"],
    ["ja", jaMessages, "すべての Cloud VM で共有するリソース", "共有"],
  ] as const) {
    test(`${locale} pricing advertises 24 GB RAM and 6 vCPUs shared across up to 50 VMs`, () => {
      const features = messages.pricing.pro.features.join("\n");
      expect(features).toContain("50 ");
      const row = messages.pricing.compare.rows.find(row => row.label === label);
      expect(row).toBeDefined();
      const faq = messages.pricing.faq.items.map(item => item.a).join("\n");
      for (const copy of [features, row!.pro, row!.team, faq]) {
        expect(copy).toContain("24 GB RAM");
        expect(copy).toContain("6 vCPU");
        expect(copy).toContain(shared);
      }
      const pricing = JSON.stringify(messages.pricing);
      expect(pricing).not.toMatch(/(?:8|32|64|256) GB|5 vCPU|each with its own resources|Each machine has its own|各マシンに専用のリソース|各マシンには独立した/);
    });
  }

  test("fallback locales inherit the shared resource wording", async () => {
    for (const locale of locales) {
      if (locale === "en" || locale === "ja") continue;
      const messages = await loadMessages(locale) as unknown as typeof enMessages;
      expect(messages.pricing.pro.features.join("\n")).toContain("24 GB RAM and 6 vCPUs shared across all VMs");
      expect(messages.pricing.compare.rows.find(row => row.label === "Resources shared across all Cloud VMs")).toBeDefined();
    }
  });

  test("native pricing keeps the shared limits in every catalog value and Swift fallback", () => {
    const catalog = JSON.parse(readFileSync(new URL("../../Resources/Localizable.xcstrings", import.meta.url), "utf8"));
    const swift = readFileSync(new URL("../../Sources/PricingPlansScreen.swift", import.meta.url), "utf8");
    for (const key of ["pricing.native.pro.feature.hours", "pricing.native.team.feature.compute", "pricing.native.sizes.body"]) {
      const localizations = catalog.strings[key].localizations as Record<string, { stringUnit: { value: string } }>;
      for (const [locale, { stringUnit: { value } }] of Object.entries(localizations)) {
        expect(value).toContain("24 GB RAM");
        expect(value).toContain("6 vCPU");
        expect(value).toContain("50 ");
        expect(value).toContain(locale === "ja" ? "共有" : "shared across all");
        expect(value).not.toMatch(/(?:8|32|64|256) GB|each with its own resources/);
      }
      expect(swift).toContain(`defaultValue: "${localizations.en.stringUnit.value}"`);
    }
  });
});
