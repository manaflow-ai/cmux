import { describe, expect, test } from "bun:test";

import { locales } from "../i18n/routing";
import {
  isPaidVmPlan,
  isVmFreeProvisioningAllowed,
  isVmProGateBlocked,
  isVmProGateEnforced,
} from "../services/vms/entitlements";
import { vmRequiresProResponse } from "../services/vms/routeHelpers";

const ent = (planId: string) => ({ planId });

describe("Cloud VM Pro gate", () => {
  test("isPaidVmPlan recognizes pro, team, and founders, not free", () => {
    expect(isPaidVmPlan("pro")).toBe(true);
    expect(isPaidVmPlan("team")).toBe(true);
    expect(isPaidVmPlan("PRO")).toBe(true);
    // Founder's Edition: one-time purchase granted via cmuxVmPlan, no
    // subscription behind it — paid for the expiry window and the pro gate.
    expect(isPaidVmPlan("founders")).toBe(true);
    expect(isPaidVmPlan("Founders")).toBe(true);
    expect(isPaidVmPlan("free")).toBe(false);
    expect(isPaidVmPlan("")).toBe(false);
    expect(isPaidVmPlan("enterprise-unknown")).toBe(false);
  });

  test("enforcement is on by default and only an explicit allow switch opens it", () => {
    expect(isVmProGateEnforced({})).toBe(true);
    expect(isVmProGateEnforced({ CMUX_VM_REQUIRE_PRO: "" })).toBe(true);
    expect(isVmProGateEnforced({ CMUX_VM_REQUIRE_PRO: "1" })).toBe(true);
    expect(isVmProGateEnforced({ CMUX_VM_ALLOW_FREE_PROVISIONING: "" })).toBe(true);
    expect(isVmProGateEnforced({ CMUX_VM_ALLOW_FREE_PROVISIONING: "0" })).toBe(true);
    expect(isVmProGateEnforced({ CMUX_VM_ALLOW_FREE_PROVISIONING: "false" })).toBe(true);
    expect(isVmProGateEnforced({ CMUX_VM_ALLOW_FREE_PROVISIONING: "1" })).toBe(false);
    expect(isVmProGateEnforced({ CMUX_VM_ALLOW_FREE_PROVISIONING: "ON" })).toBe(false);
  });

  test("legacy CMUX_VM_REQUIRE_PRO false values remain a compatibility escape hatch", () => {
    expect(isVmFreeProvisioningAllowed({ CMUX_VM_REQUIRE_PRO: "0" })).toBe(true);
    expect(isVmFreeProvisioningAllowed({ CMUX_VM_REQUIRE_PRO: "false" })).toBe(true);
    expect(isVmFreeProvisioningAllowed({ CMUX_VM_REQUIRE_PRO: "off" })).toBe(true);
    expect(isVmFreeProvisioningAllowed({ CMUX_VM_REQUIRE_PRO: "garbage" })).toBe(false);
    // The new switch is authoritative when both names are present.
    expect(isVmFreeProvisioningAllowed({
      CMUX_VM_ALLOW_FREE_PROVISIONING: "0",
      CMUX_VM_REQUIRE_PRO: "0",
    })).toBe(false);
  });

  test("the explicit free-provisioning switch never blocks any plan", () => {
    const env = { CMUX_VM_ALLOW_FREE_PROVISIONING: "1" };
    expect(isVmProGateBlocked(ent("free"), env)).toBe(false);
    expect(isVmProGateBlocked(ent("pro"), {})).toBe(false);
  });

  test("default enforcement blocks every non-paid plan but allows pro/team/founders", () => {
    const env = {};
    expect(isVmProGateBlocked(ent("free"), env)).toBe(true);
    expect(isVmProGateBlocked(ent(""), env)).toBe(true);
    expect(isVmProGateBlocked(ent("unknown"), env)).toBe(true);
    expect(isVmProGateBlocked(ent("pro"), env)).toBe(false);
    expect(isVmProGateBlocked(ent("team"), env)).toBe(false);
    expect(isVmProGateBlocked(ent("founders"), env)).toBe(false);
  });
});

describe("vm_requires_pro response copy", () => {
  test("defaults to English and keeps the machine-readable upgrade fields", async () => {
    const response = await vmRequiresProResponse();
    expect(response.status).toBe(402);
    const payload = await response.json() as Record<string, unknown>;
    expect(payload).toMatchObject({
      error: "vm_requires_pro",
      message: "Cloud VMs require a cmux Pro plan.",
      action: "Upgrade to cmux Pro at https://cmux.com/pricing to create Cloud VMs.",
      upgradeRequired: true,
      upgradeUrl: "https://cmux.com/pricing",
      ui: { title: "cmux Pro required" },
    });
  });

  test("resolves the upgrade instruction from the requested locale", async () => {
    const payload = await (await vmRequiresProResponse("ja")).json() as Record<string, unknown>;
    expect(payload.message).toBe("Cloud VM を利用するには cmux Pro プランが必要です。");
    expect(String(payload.action)).toContain("https://cmux.com/pricing");
    expect(String(payload.action)).toContain("cmux Pro にアップグレード");
    // Clients key off these, never the prose.
    expect(payload).toMatchObject({
      error: "vm_requires_pro",
      upgradeRequired: true,
      ui: { title: "cmux Pro が必要です" },
    });
  });

  test("ships translated copy with the upgrade URL placeholder in every locale catalog", async () => {
    for (const locale of locales) {
      const messages = (await import(`../messages/${locale}.json`)).default as {
        vmErrors: { requiresPro?: { title?: string; message?: string; action?: string } };
      };
      const copy = messages.vmErrors.requiresPro;
      const payload = await (await vmRequiresProResponse(locale)).json() as {
        action: string;
        ui: { title: string };
      };
      // Keyed by locale so a failure names the catalog that is missing or broken.
      expect({
        locale,
        hasMessage: Boolean(copy?.message),
        // ui.title must come from the catalog, never the English status fallback.
        uiTitleIsLocalized: Boolean(copy?.title) && payload.ui.title === copy?.title,
        actionHasPlaceholder: copy?.action?.includes("{upgradeUrl}") ?? false,
        renderedHasUrl: payload.action.includes("https://cmux.com/pricing"),
        renderedHasRawPlaceholder: payload.action.includes("{upgradeUrl}"),
      }).toEqual({
        locale,
        hasMessage: true,
        uiTitleIsLocalized: true,
        actionHasPlaceholder: true,
        renderedHasUrl: true,
        renderedHasRawPlaceholder: false,
      });
    }
  });
});
