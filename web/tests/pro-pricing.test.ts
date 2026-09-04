import { describe, expect, test } from "bun:test";

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
  PLAN_SHARED_DISK_MB,
  PLAN_SHARED_MEMORY_MB,
  PLAN_SHARED_VCPU,
  PLAN_MACHINE_MEMORY_MB,
  PAID_MAX_ACTIVE_VMS_DEFAULT,
  firstExceededSharedResource,
  sharedResourceUsage,
  sharedResourceCapacityForMaxActiveVms,
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

describe("pricing copy matches the plan policy", () => {
  // The public pricing copy states both the shared pool and the selectable
  // machine default. Pin each number to the policy constants so copy and
  // enforcement cannot drift independently.
  const sharedVcpus = PLAN_SHARED_VCPU;
  const sharedMemoryGb = PLAN_SHARED_MEMORY_MB / 1024;
  const sharedDiskGb = PLAN_SHARED_DISK_MB / 1024;
  const memoryGb = PLAN_MACHINE_MEMORY_MB / 1024;
  const startingDiskGb = VM_DISK_MB_DEFAULT / 1024;

  test("the default machine and shared Cloud VM capacity match the plan", () => {
    expect(sharedVcpus).toBe(5);
    expect(sharedMemoryGb).toBe(20);
    expect(sharedDiskGb).toBe(200);
    expect(memoryGb).toBe(8);
    expect(startingDiskGb).toBe(32);
    expect(PAID_MAX_ACTIVE_VMS_DEFAULT).toBe(50);
  });

  test("new Cloud VM disks start at 32 GB", () => {
    expect(startingDiskGb).toBe(32);
  });

  test("the shared pool scales by paid seat and sums every resource claim", () => {
    expect(sharedResourceCapacityForMaxActiveVms(PAID_MAX_ACTIVE_VMS_DEFAULT)).toEqual({
      vcpus: PLAN_SHARED_VCPU,
      memoryMb: PLAN_SHARED_MEMORY_MB,
      diskMb: PLAN_SHARED_DISK_MB,
    });
    expect(sharedResourceCapacityForMaxActiveVms(PAID_MAX_ACTIVE_VMS_DEFAULT * 2)).toEqual({
      vcpus: PLAN_SHARED_VCPU * 2,
      memoryMb: PLAN_SHARED_MEMORY_MB * 2,
      diskMb: PLAN_SHARED_DISK_MB * 2,
    });
    expect(firstExceededSharedResource({
      used: {
        vcpus: PLAN_SHARED_VCPU - 1,
        memoryMb: PLAN_SHARED_MEMORY_MB - 1,
        diskMb: PLAN_SHARED_DISK_MB - 1,
      },
      requested: { vcpus: 1, memoryMb: 1, diskMb: 2 },
      capacity: {
        vcpus: PLAN_SHARED_VCPU,
        memoryMb: PLAN_SHARED_MEMORY_MB,
        diskMb: PLAN_SHARED_DISK_MB,
      },
    })).toEqual({
      resource: "diskMb",
      used: PLAN_SHARED_DISK_MB - 1,
      requested: 2,
      limit: PLAN_SHARED_DISK_MB,
    });
    expect(sharedResourceUsage("vcpus", PLAN_SHARED_VCPU, 1)).toBe(PLAN_SHARED_VCPU + 1);
    expect(sharedResourceUsage("memoryMb", PLAN_SHARED_MEMORY_MB, 1)).toBe(PLAN_SHARED_MEMORY_MB + 1);
    expect(sharedResourceUsage("diskMb", PLAN_SHARED_DISK_MB - 1, 2)).toBe(PLAN_SHARED_DISK_MB + 1);
    expect(firstExceededSharedResource({
      used: {
        vcpus: PLAN_SHARED_VCPU - 1,
        memoryMb: PLAN_SHARED_MEMORY_MB - 1,
        diskMb: VM_DISK_MB_DEFAULT,
      },
      requested: {
        vcpus: 1,
        memoryMb: 1,
        diskMb: VM_DISK_MB_DEFAULT,
      },
      capacity: {
        vcpus: PLAN_SHARED_VCPU,
        memoryMb: PLAN_SHARED_MEMORY_MB,
        diskMb: PLAN_SHARED_DISK_MB,
      },
    })).toBeNull();
    expect(firstExceededSharedResource({
      used: { vcpus: PLAN_SHARED_VCPU - 1, memoryMb: 0, diskMb: 0 },
      requested: { vcpus: 2, memoryMb: 1, diskMb: 1 },
      capacity: {
        vcpus: PLAN_SHARED_VCPU,
        memoryMb: PLAN_SHARED_MEMORY_MB,
        diskMb: PLAN_SHARED_DISK_MB,
      },
    })).toEqual({
      resource: "vcpus",
      used: PLAN_SHARED_VCPU - 1,
      requested: 2,
      limit: PLAN_SHARED_VCPU,
    });
  });

  test("a size-less plan reservation follows requested memory", () => {
    expect(vmResourceReservationForCreate({
      memoryMb: PLAN_SHARED_MEMORY_MB,
      env: {},
    })).toEqual({
      vcpus: PLAN_SHARED_VCPU,
      memoryMb: PLAN_SHARED_MEMORY_MB,
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

  for (const [
    locale,
    messages,
    sharedPhrase,
    stalePerVmPhrase,
    capacityLabel,
    faqSharedPhrase,
    faqPerUserPhrase,
    startingDiskPhrase,
  ] of [
    [
      "en",
      enMessages,
      "all sharing a total pool of",
      "each with",
      "Resources shared across Cloud VMs",
      "Pro includes up to 50 machines sharing a total pool of 5 vCPU, 20 GB of RAM, and 200 GB of disk",
      "same shared pool for each user",
      "New VM disks start at 32 GB",
    ],
    [
      "ja",
      jaMessages,
      "すべての VM で合計",
      "各 5 vCPU",
      "Cloud VM 間で共有するリソース",
      "Pro では最大 50 台のマシンで合計 5 vCPU、20 GB の RAM、200 GB のディスクを共有",
      "Team では、ユーザーごとに最大 50 台のマシンと同じ共有プール",
      "新しい VM のディスクは 32 GB で開始",
    ],
  ] as const) {
    test(`${locale} pricing copy states the current prices and shared capacity`, () => {
      const pricing = messages.pricing;
      const proFeatures = pricing.pro.features.join("\n");
      expect(proFeatures).toContain(`${PAID_MAX_ACTIVE_VMS_DEFAULT} `);
      expect(proFeatures).toContain(`${sharedVcpus} vCPU`);
      expect(proFeatures).toContain(`${sharedMemoryGb} GB`);
      expect(proFeatures).toContain(`${sharedDiskGb} GB`);
      expect(proFeatures).toContain(sharedPhrase);
      expect(proFeatures).toContain(`${memoryGb} GB`);
      expect(proFeatures).toContain(`${startingDiskGb} GB`);
      expect(proFeatures).not.toContain(stalePerVmPhrase);

      const vmRow = pricing.compare.rows.find((row) =>
        row.label.includes("Cloud VM") && row.pro === String(PAID_MAX_ACTIVE_VMS_DEFAULT),
      );
      expect(vmRow).toBeDefined();
      const capacityRow = pricing.compare.rows.find((row) => row.label === capacityLabel);
      expect(capacityRow?.pro).toContain(`${sharedVcpus} vCPU`);
      expect(capacityRow?.pro).toContain(`${sharedMemoryGb} GB`);
      expect(capacityRow?.pro).toContain(`${sharedDiskGb} GB`);
      expect(capacityRow?.pro).toContain(`${memoryGb} GB`);
      expect(capacityRow?.pro).toContain(`${startingDiskGb} GB`);
      expect(capacityRow?.team).toContain(`${sharedVcpus} vCPU`);
      expect(capacityRow?.team).toContain(`${sharedMemoryGb} GB`);
      expect(capacityRow?.team).toContain(`${sharedDiskGb} GB`);
      expect(capacityRow?.team).toContain(`${memoryGb} GB`);
      expect(capacityRow?.team).toContain(`${startingDiskGb} GB`);
      const teamCapacity = capacityRow?.team ?? "";
      expect(locale === "en" ? teamCapacity.toLowerCase() : teamCapacity).toContain(
        locale === "en" ? "per user" : "ユーザーごとに",
      );

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
      expect(faq).not.toContain(stalePerVmPhrase);
      expect(faq).toContain(faqSharedPhrase);
      expect(faq).toContain(faqPerUserPhrase);
      expect(faq).toContain(startingDiskPhrase);
      if (locale === "en") {
        expect(faq).toContain("Team includes up to 50 machines per user");
      } else {
        expect(faq).toContain("Team では、ユーザーごとに最大 50 台のマシン");
      }
    });
  }

  test("fallback locales inherit the shared English VM policy", async () => {
    for (const locale of locales) {
      if (locale === "en" || locale === "ja") continue;
      const messages = await loadMessages(locale) as unknown as typeof enMessages;
      const pricing = messages.pricing;
      const proFeatures = pricing.pro.features.join("\n");
      expect(proFeatures).toContain("all sharing a total pool of 5 vCPU, 20 GB RAM, and 200 GB disk");
      expect(proFeatures).not.toContain("each with 5 vCPU");
      const capacityRow = pricing.compare.rows.find((row) => row.label === "Resources shared across Cloud VMs");
      expect(capacityRow?.pro).toBe("5 vCPU, 20 GB RAM, 200 GB disk total; default VM size 8 GB RAM and 32 GB disk, with sizes from 4 to 64 GB RAM available as capacity allows");
      expect(capacityRow?.team).toBe("Per user: 5 vCPU, 20 GB RAM, and 200 GB disk total; default VM size 8 GB RAM and 32 GB disk, with sizes from 4 to 64 GB RAM available as capacity allows");
      const faq = pricing.faq.items.map((item) => item.a).join("\n");
      expect(faq).toContain("Pro includes up to 50 machines sharing a total pool of 5 vCPU, 20 GB of RAM, and 200 GB of disk");
    }
  });
});
