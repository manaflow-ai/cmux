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
  test("prices Pro at $50/mo without a new annual offer", () => {
    expect(PRO_PRICING_USD.month).toEqual({
      billedAmount: 50,
      monthlyEquivalent: 50,
      discountPercent: 0,
      lookupKey: "cmux-pro-monthly-50",
    });
    expect("year" in PRO_PRICING_USD).toBe(false);
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

  test("prices Max at $200/mo, monthly only", () => {
    expect(MAX_PRICING_USD).toEqual({
      month: {
        billedAmount: 200,
        monthlyEquivalent: 200,
        discountPercent: 0,
        lookupKey: "cmux-max-monthly-200",
      },
    });
    expect("year" in MAX_PRICING_USD).toBe(false);
    expect(MAX_BILLING_INTERVALS).toEqual(["month"]);
  });

  test("lookup keys carry their amount and never reuse a grandfathered key", () => {
    const current = [
      PRO_PRICING_USD.month,
      MAX_PRICING_USD.month,
      TEAM_PRICING_USD.month,
    ];
    for (const price of current) {
      expect(price.lookupKey.endsWith(`-${price.billedAmount}`)).toBe(true);
      expect(LEGACY_PRICE_LOOKUP_KEYS).not.toContain(price.lookupKey);
    }
    expect(LEGACY_PRICE_LOOKUP_KEYS).toEqual([
      "cmux-pro-monthly",
      "cmux-pro-yearly",
      "cmux-pro-yearly-288",
      "cmux-pro-yearly-480",
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
    expect(PAID_MAX_ACTIVE_VMS_DEFAULT).toBe(5);
    expect(memoryGb).toBe(8);
    expect(startingDiskGb).toBe(32);
  });

  test("a size-less plan reservation follows requested memory", () => {
    expect(vmResourceReservationForCreate({
      memoryMb: 32768,
      env: {},
    })).toEqual({
      vcpus: 16,
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

  // These are the advertised plan limits: a machine count, one vCPU and
  // memory pool shared by those machines, and the largest single machine.
  // Keep cards, comparison rows, FAQs, and native strings on the same policy.
  for (const [locale, messages, label] of [
    ["en", enMessages, "Cloud VM resources"],
    ["ja", jaMessages, "Cloud VM リソース"],
  ] as const) {
    test(`${locale} pricing advertises up to 5 VMs sharing 20 vCPUs and 40 GB RAM`, () => {
      const features = messages.pricing.pro.features.join("\n");
      expect(features).toMatch(/(?:^|\D)5(?:\D|$)/);
      const row = messages.pricing.compare.rows.find(row => row.label === label);
      expect(row).toBeDefined();
      const faq = messages.pricing.faq.items.map(item => item.a).join("\n");
      for (const copy of [features, row!.pro, row!.team, faq]) {
        expect(copy).toContain("20 vCPU");
        expect(copy).toContain("40 GB RAM");
      }
      expect(row!.max).toContain("80 vCPU");
      expect(row!.max).toContain("160 GB RAM");
      // The retired per-VM limits and shared-pool numbers must not come back.
      expect(JSON.stringify(messages.pricing)).not.toMatch(/per VM|VM あたり|4 vCPU|8 GB RAM|24 GB|50 Cloud VMs|6 vCPUs shared/);
      expect(JSON.stringify(messages.dashboard.billing)).not.toMatch(/per VM|VM あたり|(?:^|\D)4 vCPU/);
    });
  }

  for (const [locale, messages, largestLabel, faqQuestion, poolSentence] of [
    ["en", enMessages, "Largest Cloud VM", "What does Max add?", "Your VMs draw from one pool. Run one large VM or five small ones. Paused VMs do not use the pool."],
    ["ja", jaMessages, "最大の Cloud VM", "Max では何が追加されますか?", "VM は 1 つのプールからリソースを使います。大きな VM 1 台でも、小さな VM 5 台でも動かせます。一時停止中の VM はプールを使いません。"],
  ] as const) {
    test(`${locale} Max copy sells up to 5 VMs sharing 80 vCPUs and 160 GB RAM`, () => {
      const features = messages.pricing.max.features.join("\n");
      expect(features).toContain("80 vCPU");
      expect(features).toContain("160 GB");
      expect(features).toMatch(/(?:^|\D)5(?:\D|$)/);
      expect(messages.dashboard.billing.max.upsell).toContain("80 vCPU");
      expect(messages.dashboard.billing.max.upsell).toContain("160 GB");
      const row = messages.pricing.compare.rows.find(row => row.label === largestLabel);
      expect(row).toBeDefined();
      expect(row!.max).toBe("64 GB RAM");
      for (const plan of ["pro", "team"] as const) {
        expect(row![plan]).toBe("32 GB RAM");
      }
      // Free accounts include no Cloud VM at all.
      expect(row!.free).toBe("false");
      for (const row of messages.pricing.compare.rows) {
        expect(typeof row.max).toBe("string");
      }
      const faq = messages.pricing.faq.items.find(item => item.q === faqQuestion);
      expect(faq).toBeDefined();
      expect(faq!.a).toContain("$200");
      expect(faq!.a).toContain("80 vCPU");
      expect(faq!.a).toContain("160 GB");
      expect(faq!.a).toContain("20 vCPU");
      expect(faq!.a).toContain("40 GB");
      expect(faq!.a).toContain(poolSentence);
      const billingFaq = messages.pricing.faq.items.map(item => item.a).join("\n");
      expect(billingFaq).toContain("$200");
    });
  }

  test("fallback locales inherit the pooled resource wording", async () => {
    for (const locale of locales) {
      if (locale === "en" || locale === "ja") continue;
      const messages = await loadMessages(locale) as unknown as typeof enMessages;
      expect(messages.pricing.pro.features.join("\n")).toContain("Up to 5 Cloud VMs sharing 20 vCPUs and 40 GB RAM");
      expect(messages.pricing.max.features[0]).toBe("Up to 5 Cloud VMs sharing 80 vCPUs and 160 GB RAM");
      expect(messages.pricing.compare.rows.find(row => row.label === "Cloud VM resources")).toBeDefined();
    }
  });

  test("every locale's plan picker and resource-pool error keep the pool numbers and placeholders", async () => {
    for (const locale of locales) {
      const messages = await loadMessages(locale) as unknown as typeof enMessages;
      const picker = messages.dashboard.billing.picker.features;
      for (const quantity of ["5", "20", "40"]) expect(picker.pro.join("\n")).toContain(quantity);
      for (const quantity of ["5", "80", "160"]) expect(picker.max.join("\n")).toContain(quantity);
      expect(JSON.stringify(picker)).not.toMatch(/(?:^|\D)(?:4 vCPU|8 GB|16 vCPU|32 GB)/);
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
        if (/(?<!\d)50(?!\d)|(?<!\d)24\s?(?:GB|Go)|\btrial\b|\$480/i.test(withoutPrice)) {
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
        expect(value).not.toMatch(/(?:^|\D)(?:6|24|50|64)(?:\D|$)/);
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
