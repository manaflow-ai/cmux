import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";

import enMessages from "../messages/en.json";
import jaMessages from "../messages/ja.json";
import { loadMessages } from "../i18n/messages";
import { locales } from "../i18n/routing";
import {
  LEGACY_PRICE_LOOKUP_KEYS,
  MAX_BILLING_INTERVALS,
  MAX_PRICING_USD,
  GO_PRICING_USD,
  PRO_PRICING_USD,
  TEAM_PRICING_USD,
  proBillingInterval,
} from "../services/billing/plans";
import {
  PLAN_MACHINE_MEMORY_MB,
  vmResourceReservationForCreate,
  VM_DISK_MB_DEFAULT,
} from "../services/vms/entitlements";

describe("pricing plans", () => {
  test("prices Pro at $50/mo or $480/yr", () => {
    expect(PRO_PRICING_USD).toEqual({
      month: {
        billedAmount: 50,
        monthlyEquivalent: 50,
        discountPercent: 0,
        lookupKey: "cmux-pro-monthly-50",
      },
      year: {
        billedAmount: 480,
        monthlyEquivalent: 40,
        discountPercent: 20,
        lookupKey: "cmux-pro-yearly-480",
      },
    });
  });

  test("prices Team at $60/user/mo without a new annual offer", () => {
    expect(TEAM_PRICING_USD.month).toEqual({
      billedAmount: 60,
      monthlyEquivalent: 60,
      discountPercent: 0,
      lookupKey: "cmux-team-monthly-60",
    });
    expect("year" in TEAM_PRICING_USD).toBe(false);
  });

  test("prices Max at $200/mo or $1,920/yr with the same 20% discount", () => {
    expect(MAX_PRICING_USD).toEqual({
      month: {
        billedAmount: 200,
        monthlyEquivalent: 200,
        discountPercent: 0,
        lookupKey: "cmux-max-monthly-200",
      },
      year: {
        billedAmount: 1920,
        monthlyEquivalent: 160,
        discountPercent: 20,
        lookupKey: "cmux-max-yearly-1920",
      },
    });
    expect(MAX_BILLING_INTERVALS).toEqual(["month", "year"]);
  });

  test("lookup keys carry their amount and never reuse a grandfathered key", () => {
    const current = [
      GO_PRICING_USD.month,
      PRO_PRICING_USD.month,
      PRO_PRICING_USD.year,
      MAX_PRICING_USD.month,
      TEAM_PRICING_USD.month,
    ];
    for (const price of current) {
      expect(price.lookupKey.endsWith(`-${price.billedAmount}`)).toBe(true);
      expect(LEGACY_PRICE_LOOKUP_KEYS).not.toContain(price.lookupKey);
    }
    expect(LEGACY_PRICE_LOOKUP_KEYS).toEqual([
      "cmux-starter-monthly-20",
      "cmux-go-monthly-10",
      "cmux-pro-monthly",
      "cmux-pro-yearly",
      "cmux-pro-yearly-288",
      "cmux-team-monthly",
      "cmux-team-yearly-336",
      "cmux-team-yearly-576",
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
  test("VM creation defaults are separate from advertised plan limits", () => {
    expect(memoryGb).toBe(8);
    expect(startingDiskGb).toBe(32);
  });

  test("a size-less plan reservation follows requested memory", () => {
    expect(vmResourceReservationForCreate({
      memoryMb: 16384,
      env: {},
    })).toEqual({
      vcpus: 8,
      memoryMb: 16384,
      diskMb: VM_DISK_MB_DEFAULT,
    });
  });

  test("a sized image reserves its complete provider shape", () => {
    expect(vmResourceReservationForCreate({
      imageSize: { cpu: 8, memoryMb: 16384, storageMb: 65536 },
    })).toEqual({ vcpus: 8, memoryMb: 16384, diskMb: 65536 });
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

  // Paid plans have no machine count (Leo, 2026-11-10: "you can have arbitrarily many VMs and we just build
  // based off of that kind of thing"): machines are metered beyond the included usage and the spending cap is
  // the stop. The copy names sizes, never a count or a per-seat count, and adds no dollar numbers.
  const RETIRED_COUNT = /(?:^|\D)5 (?:Cloud VMs|VMs|machines)|up to 5|最大 ?5 ?台|5 per paid seat|per paid seat|シートごと/i;
  for (const [locale, messages, savedLabel, resourcesLabel, noCap] of [
    ["en", enMessages, "Saved Cloud VMs, including paused machines", "Cloud VM resources", "No cap"],
    ["ja", jaMessages, "保存済み Cloud VM 数（一時停止中を含む）", "Cloud VM リソース", "上限なし"],
  ] as const) {
    test(`${locale} pricing gives paid plans no machine count and says use past the included amount is metered`, () => {
      for (const plan of ["pro", "max", "team"] as const) {
        expect(messages.pricing[plan].features.join("\n")).not.toMatch(RETIRED_COUNT);
      }
      expect(JSON.stringify(messages.dashboard.billing)).not.toMatch(RETIRED_COUNT);
      const faq = messages.pricing.faq.items.map(item => item.a).join("\n");
      expect(faq).not.toMatch(RETIRED_COUNT);
      const saved = messages.pricing.compare.rows.find(row => row.label === savedLabel);
      expect(saved).toBeDefined();
      expect([saved!.pro, saved!.max, saved!.team]).toEqual([noCap, noCap, noCap]);
      // Plus is sold as one saved machine and keeps it; Free has none.
      expect(saved!.go).toBe("1");
      expect(saved!.free).toBe("false");
      const resources = messages.pricing.compare.rows.find(row => row.label === resourcesLabel);
      expect(resources).toBeDefined();
      for (const copy of [resources!.pro, resources!.max, resources!.team]) expect(copy).not.toMatch(/\d/);
      const features = messages.pricing.pro.features.join("\n");
      for (const copy of [features, faq]) {
        expect(copy).toContain("24 GB / 12 vCPU");
        expect(copy).toContain("32 GB / 16 vCPU");
      }
      // The retired per-VM limits and shared-pool numbers must not come back.
      expect(JSON.stringify(messages.pricing)).not.toMatch(/per VM|VM あたり|4 vCPU|8 GB RAM|50 Cloud VMs|6 vCPUs shared|20 vCPUs and 40 GB|80 vCPUs and 160 GB/);
      expect(JSON.stringify(messages.dashboard.billing)).not.toMatch(/per VM|VM あたり|(?:^|\D)4 vCPU/);
    });
  }

  for (const [locale, messages, largestLabel, faqQuestion] of [
    ["en", enMessages, "Largest Cloud VM", "What does Max add?"],
    ["ja", jaMessages, "最大の Cloud VM", "Max では何が追加されますか?"],
  ] as const) {
    test(`${locale} Max copy sells the larger sizes, not a machine count`, () => {
      const features = messages.pricing.max.features.join("\n");
      expect(features).toContain("64 GB / 32 vCPU");
      expect(features).not.toMatch(RETIRED_COUNT);
      expect(messages.dashboard.billing.max.upsell).toContain("64 GB RAM / 32 vCPU");
      expect(messages.dashboard.billing.max.upsell).toContain("$200");
      const row = messages.pricing.compare.rows.find(row => row.label === largestLabel);
      expect(row).toBeDefined();
      expect(row!.max).toContain("64 GB RAM");
      expect(row!.max).toContain("32 vCPU");
      for (const plan of ["pro", "team"] as const) {
        expect(row![plan]).toContain("16 GB RAM");
        expect(row![plan]).toContain("8 vCPU");
      }
      // Free accounts include no Cloud VM at all.
      expect(row!.free).toBe("false");
      for (const row of messages.pricing.compare.rows) {
        expect(typeof row.max).toBe("string");
      }
      const faq = messages.pricing.faq.items.find(item => item.q === faqQuestion);
      expect(faq).toBeDefined();
      expect(faq!.a).toContain("$200");
      expect(faq!.a).toContain("24 GB / 12 vCPU");
      expect(faq!.a).toContain("32 GB / 16 vCPU");
      expect(faq!.a).not.toMatch(RETIRED_COUNT);
      const billingFaq = messages.pricing.faq.items.map(item => item.a).join("\n");
      expect(billingFaq).toContain("$200");
    });
  }

  test("fallback locales inherit the no-count wording", async () => {
    for (const locale of locales) {
      if (locale === "en" || locale === "ja") continue;
      const messages = await loadMessages(locale) as unknown as typeof enMessages;
      const proCopy = messages.pricing.pro.features.join("\n");
      const maxCopy = messages.pricing.max.features.join("\n");
      expect(proCopy).not.toMatch(RETIRED_COUNT);
      expect(maxCopy).not.toMatch(RETIRED_COUNT);
      expect(proCopy).toContain("12 vCPU");
      expect(proCopy).toContain("16 vCPU");
      expect(maxCopy).toContain("12 vCPU");
      expect(maxCopy).toContain("16 vCPU");
      expect(messages.pricing.compare.rows.find(row => row.label === "Cloud VM resources")).toBeDefined();
    }
  });

  test("every locale's plan picker and resource-pool error keep the pool numbers and placeholders", async () => {
    for (const locale of locales) {
      const messages = await loadMessages(locale) as unknown as typeof enMessages;
      const picker = messages.dashboard.billing.picker.features;
      for (const plan of [picker.pro, picker.max, picker.team]) expect(plan.join("\n")).not.toMatch(/(?:^|\D)5(?:\D|$)/);
      for (const quantity of ["16", "8 vCPU"]) expect(picker.pro.join("\n")).toContain(quantity);
      for (const quantity of ["64", "32 vCPU"]) expect(picker.max.join("\n")).toContain(quantity);
      expect(JSON.stringify(picker)).not.toMatch(/(?:^|\D)(?:4 vCPU|8 GB RAM)/);
      const sizeError = messages.docs.cloudTroubleshooting.fixSize;
      expect(sizeError).toContain("16");
      expect(sizeError).not.toContain("32 GB");
      expect(messages.docs.cloudMachines.limitsMax).toContain("24 GB / 12 vCPU");
      expect(messages.docs.cloudMachines.limitsMax).toContain("32 GB / 16 vCPU");
      const pool = messages.vmErrors.resourcePool;
      for (const key of ["memoryMessage", "vcpuMessage"] as const) {
        for (const placeholder of ["{used}", "{pool}", "{requested}"]) {
          expect(pool[key]).toContain(placeholder);
        }
      }
      expect(pool.title.length).toBeGreaterThan(0);
      expect(pool.upgradeAction).toContain("Max");
      expect(pool.action.length).toBeGreaterThan(0);
    }
  });

  // On feat-cmux-next the legacy Resources/Localizable.xcstrings no longer carries the
  // pricing.native.* keys, and cmux-next has no native pricing strings yet. Re-enable
  // against cmux-next's catalog when it gets a native pricing screen.
  test.skip("no native pricing string in any locale sells the retired limits or a free trial", () => {
    const catalog = JSON.parse(readFileSync(new URL("../../Resources/Localizable.xcstrings", import.meta.url), "utf8"));
    const stale: string[] = [];
    for (const [key, entry] of Object.entries(catalog.strings as Record<string, { localizations?: Record<string, { stringUnit?: { value?: string } }> }>)) {
      if (!key.startsWith("pricing.native.") && !key.startsWith("settings.account.pro.")) continue;
      for (const [locale, localization] of Object.entries(entry.localizations ?? {})) {
        const value = localization.stringUnit?.value ?? "";
        // Remove only the $50 Pro price tokens, so a stale "50 Cloud VMs"
        // elsewhere in the same value still fails.
        const withoutPrice = value.replace(/^\$?50$|\$50\/?|(?<!\d)50\s?\$|(?<!\d)50\s*美元/g, "");
        if (/(?<!\d)50(?!\d)|\btrial\b|\$480/i.test(withoutPrice)) {
          stale.push(`${key} ${locale}: ${value}`);
        }
      }
    }
    expect(stale).toEqual([]);
  });

  // On feat-cmux-next the legacy Resources/Localizable.xcstrings no longer carries the
  // pricing.native.* keys, and cmux-next has no native pricing strings yet. Re-enable
  // against cmux-next's catalog when it gets a native pricing screen.
  test.skip("native pricing translations preserve the plan quantities", () => {
    const catalog = JSON.parse(readFileSync(new URL("../../Resources/Localizable.xcstrings", import.meta.url), "utf8"));
    for (const key of ["pricing.native.pro.feature.hours", "pricing.native.team.feature.compute", "pricing.native.sizes.body"]) {
      const localizations = catalog.strings[key].localizations as Record<string, { stringUnit: { value: string } }>;
      for (const [, { stringUnit: { value } }] of Object.entries(localizations)) {
        // Units and word order are localized; the pooled quantities stay the same.
        for (const quantity of [5, 20, 40]) {
          expect(value).toMatch(new RegExp(`(?:^|\\D)${quantity}(?:\\D|$)`));
        }
        // 24/32/64 GB and 12/16/32 vCPU are current Max offerings and may
        // appear in the explanatory size ladder copy.
        expect(value).not.toMatch(/(?:^|\D)(?:6|50)(?:\D|$)/);
      }
    }
    for (const key of ["pricing.native.max.feature.sizes", "pricing.native.sizes.max"]) {
      const localizations = catalog.strings[key].localizations as Record<string, { stringUnit: { value: string } }>;
      for (const [, { stringUnit: { value } }] of Object.entries(localizations)) {
        for (const quantity of [5, 80, 160]) {
          expect(value).toMatch(new RegExp(`(?:^|\\D)${quantity}(?:\\D|$)`));
        }
        expect(value).not.toMatch(/(?:^|\D)50(?:\D|$)/);
      }
    }
  });

});
