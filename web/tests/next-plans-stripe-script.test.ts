import { describe, expect, setDefaultTimeout, test } from "bun:test";

import { NEXT_PLAN_OFFERS } from "../services/billing/nextPlans";
import { runChild } from "./helpers/run-child";
import { NEXT_MAX_PRICING_USD, NEXT_PLUS_PRICING_USD, NEXT_PRO_PRICING_USD } from "../services/billing/plans";

const SCRIPT = "scripts/stripe/provision-next-plans.sh";

describe("provision-next-plans.sh (the cmux NEXT Stripe catalog)", () => {
  test("sells the same plans, amounts, lookup keys and limits as the site", async () => {
    const out = await runChild("bash", [SCRIPT, "test"], { env: { ...process.env, CMUX_NEXT_PLANS_PRINT: "1" } });
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

  test("a live write needs the explicit confirmation", async () => {
    const out = await runChild("bash", [SCRIPT, "live", "--apply"], { env: { ...process.env, CMUX_STRIPE_LIVE_CONFIRM: "" } });
    expect(out.status).toBe(1);
    expect(out.stderr).toContain("CMUX_STRIPE_LIVE_CONFIRM=next-plans");
  });
});

// A fake Stripe: `curl` on PATH answers each request from the scenario's JSON and logs its arguments.
async function runAgainstFakeStripe(price: Record<string, unknown> | null, args: string[] = ["test", "--apply"], searchFinds = true) {
  const { mkdtempSync, mkdirSync, writeFileSync, readFileSync, chmodSync } = await import("node:fs");
  const { tmpdir } = await import("node:os");
  const { join } = await import("node:path");
  const root = mkdtempSync(join(tmpdir(), "next-plans-stripe-"));
  mkdirSync(join(root, "bin"));
  mkdirSync(join(root, "home/.secrets"), { recursive: true });
  writeFileSync(join(root, "home/.secrets/cmux-stripe-test.env"), "STRIPE_TEST_PROVISION_KEY=sk_test_fake\n");
  const product = { id: "prod_existing", name: "", description: "" };
  writeFileSync(join(root, "products.json"), JSON.stringify({ data: searchFinds ? [product] : [] }));
  writeFileSync(join(root, "prices.json"), JSON.stringify({ data: price ? [price] : [] }));
  writeFileSync(
    join(root, "bin/curl"),
    `#!/bin/bash
cat >/dev/null
printf '%s\\n' "$*" >> "${root}/calls.log"
case "$*" in
  *"/products/search"*) cat "${root}/products.json" ;;
  *"lookup_keys"*"cmux-next-plus-monthly-20"*) cat "${root}/prices.json" ;;
  *"lookup_keys"*) echo '{"data":[]}' ;;
  *"-X POST"*"/prices"*) echo '{"id":"price_new"}' ;;
  *) echo '{"id":"prod_existing"}' ;;
esac
`,
  );
  chmodSync(join(root, "bin/curl"), 0o755);
  const out = await runChild("bash", [SCRIPT, ...args], {
    env: { ...process.env, HOME: join(root, "home"), PATH: `${join(root, "bin")}:${process.env.PATH}` },
  });
  let calls = "";
  try {
    calls = readFileSync(join(root, "calls.log"), "utf8");
  } catch {}
  return { ...out, calls };
}

const goodPrice = (over: Record<string, unknown> = {}) => ({
  id: "price_ok",
  unit_amount: 2000,
  product: { id: "prod_existing", metadata: { app: "cmux", plan: "next_plus" } },
  active: true,
  currency: "usd",
  recurring: { interval: "month", interval_count: 1 },
  ...over,
});

describe("provision-next-plans.sh against Stripe (a fake one)", () => {
  setDefaultTimeout(30_000);
  test("an existing Price that checkout would refuse is reported, never printed as the id to deploy", async () => {
    for (const bad of [
      { product: { id: "prod_other", metadata: {} } },
      { product: { id: "prod_existing", deleted: true, metadata: { app: "cmux", plan: "next_plus" } } },
      { active: false }, { currency: "eur" }, { recurring: { interval: "year", interval_count: 1 } }, { recurring: { interval: "month", interval_count: 3 } },
    ]) {
      const out = await runAgainstFakeStripe(goodPrice(bad));
      expect(out.status).toBe(1);
      expect(out.stderr).toContain("left alone");
      expect(out.stdout).not.toContain("price_ok");
    }
  });

  test("with no Product found by search, a Price on a Product that is not this plan's is still refused", async () => {
    const out = await runAgainstFakeStripe(goodPrice({ product: { id: "prod_foreign", metadata: { app: "other" } } }), ["test"], false);
    expect(out.status).toBe(1);
    expect(out.stderr).toContain("left alone");
    expect(out.stdout).not.toContain("price_ok");
  });

  test("a dashboard-made Price is reused with its own Product even before search finds it: no second Product", async () => {
    const out = await runAgainstFakeStripe(goodPrice(), ["test", "--apply"], false);
    expect(out.calls).not.toContain("Idempotency-Key: cmux-next-test-v1-product-next_plus");
    expect(out.stderr).toContain("price price_ok (cmux-next-plus-monthly-20, 2000 cents a month) is current on product prod_existing");
    expect(out.stdout).toContain("STRIPE_PRICE_NEXT_PLUS_MONTHLY=price_ok");
  });

  test("a matching Price is current for Plus; creates carry a stable Idempotency-Key", async () => {
    const out = await runAgainstFakeStripe(null);
    expect(out.status).toBe(0);
    expect(out.calls).toContain("Idempotency-Key: cmux-next-test-v1-price-cmux-next-plus-monthly-20");
    expect(out.calls).toContain("Idempotency-Key: cmux-next-test-v1-price-cmux-next-max-monthly-200");
    expect(out.stdout).toContain("STRIPE_PRICE_NEXT_PLUS_MONTHLY=price_new");
    const current = await runAgainstFakeStripe(goodPrice(), ["test"]);
    expect(current.stderr).toContain("price price_ok (cmux-next-plus-monthly-20, 2000 cents a month) is current on product prod_existing");
  });
});
