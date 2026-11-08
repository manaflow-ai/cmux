import { describe, expect, test } from "bun:test";
import { backfillPaidPurchasesByEmail } from "../services/billing/backfillPaidPurchases";
import type { PaidBillingPurchase } from "../services/billing/recovery";

async function* emailsOf(items: string[]) {
  for (const item of items) yield item;
}

const purchase = (kind: PaidBillingPurchase["kind"]): PaidBillingPurchase =>
  ({ kind, input: { session: { id: `cs_${kind}` } } }) as unknown as PaidBillingPurchase;

describe("backfill paid purchases by email", () => {
  const emails = ["Founder@Example.com", "founder@example.com", "pro@example.com", "nobody@example.com", "free@example.com"];
  const find = async (email: string) => {
    if (email.startsWith("founder")) return purchase("founders_edition");
    if (email.startsWith("pro") || email.startsWith("nobody")) return purchase("pro");
    return null;
  };
  const hasStackUser = async (email: string) => !email.startsWith("nobody");

  test("dry run dedupes emails, reports purchases, and flags missing Stack accounts", async () => {
    const provisioned: string[] = [];
    const lines: string[] = [];
    const result = await backfillPaidPurchasesByEmail({
      emails: () => emailsOf(emails),
      find,
      hasStackUser,
      provision: async (item) => { provisioned.push(item.kind); return { scope: "user" }; },
      log: (line) => lines.push(line),
    });

    expect(provisioned).toEqual([]);
    expect(result).toMatchObject({ customers: 4, found: 3, provisioned: 0, noStackUser: 1, failed: 0 });
    expect(lines.some((line) => line.startsWith("would provision founders_edition fo***@example.com"))).toBe(true);
    expect(lines.some((line) => line.startsWith("no stack user pro no***@example.com"))).toBe(true);
    expect(lines.join("\n")).not.toContain("nobody@example.com");
  });

  test("apply provisions found purchases, skips missing accounts unless allowed, and collects failures", async () => {
    const provisioned: string[] = [];
    const result = await backfillPaidPurchasesByEmail({
      mode: "apply",
      emails: () => emailsOf(emails),
      find,
      hasStackUser,
      provision: async (item) => {
        provisioned.push(item.kind);
        if (item.kind === "pro") throw new Error("boom");
        return { scope: "user", stackUserId: "u1", subscriptionId: "sub" };
      },
    });
    expect(provisioned).toEqual(["founders_edition", "pro"]);
    expect(result).toMatchObject({ customers: 4, found: 3, provisioned: 1, noStackUser: 1, failed: 1 });

    const withCreate = await backfillPaidPurchasesByEmail({
      mode: "apply",
      createMissingUsers: true,
      emails: () => emailsOf(["nobody@example.com"]),
      find,
      hasStackUser,
      provision: async () => ({ skipped: "account_deletion_in_progress" }),
    });
    expect(withCreate).toMatchObject({ customers: 1, found: 1, provisioned: 0, skipped: 1, noStackUser: 0 });
  });
});
