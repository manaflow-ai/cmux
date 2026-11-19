import { spawnSync } from "node:child_process";

import { describe, expect, test } from "bun:test";

import { NEXT_PLAN_OFFERS } from "../services/billing/nextPlans";
import { NEXT_MAX_PRICING_USD, NEXT_PLUS_PRICING_USD, NEXT_PRO_PRICING_USD } from "../services/billing/plans";

const SCRIPT = "scripts/stripe/provision-next-plans.sh";

describe("provision-next-plans.sh (the cmux NEXT Stripe catalog)", () => {
  test("sells the same plans, amounts, lookup keys and limits as the site", () => {
    const out = spawnSync("bash", [SCRIPT, "test"], { env: { ...process.env, CMUX_NEXT_PLANS_PRINT: "1" }, encoding: "utf8" });
    expect(out.status).toBe(0);
    const rows: string[][] = out.stdout.trim().split("\n").map((line: string) => line.split("|"));
    const prices = [NEXT_PLUS_PRICING_USD, NEXT_PRO_PRICING_USD, NEXT_MAX_PRICING_USD];
    expect(rows.map(([plan, , cents, lookup]) => [plan, Number(cents) / 100, lookup])).toEqual(
      prices.map((p, i) => [NEXT_PLAN_OFFERS[i]!.id, p.month.billedAmount, p.month.lookupKey]),
    );
    for (const [i, row] of rows.entries()) {
      const offer = NEXT_PLAN_OFFERS[i]!;
      expect(row[4]).toContain(`Up to ${offer.maxRunningMachines} Cloud machines running at once`);
      expect(row[4]).toContain(`${offer.largestMachine.vcpus} vCPU and ${offer.largestMachine.memoryGib} GB RAM with a ${offer.maxDiskGib} GB disk`);
      expect(row[4]).toContain(`${offer.includedMachineMinutes.toLocaleString("en-US")} machine minutes included each month`);
    }
  });

  test("a live write needs the explicit confirmation", () => {
    const out = spawnSync("bash", [SCRIPT, "live", "--apply"], { env: { ...process.env, CMUX_STRIPE_LIVE_CONFIRM: "" }, encoding: "utf8" });
    expect(out.status).toBe(1);
    expect(out.stderr).toContain("CMUX_STRIPE_LIVE_CONFIRM=next-plans");
  });
});
