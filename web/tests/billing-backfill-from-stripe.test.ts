import { describe, expect, test } from "bun:test";
import type Stripe from "stripe";
import { backfillSubscriptionsFromStripe } from "../services/billing/backfillFromStripe";

function subscription(
  id: string,
  metadata: Record<string, string>,
  status: Stripe.Subscription.Status = "active",
): Stripe.Subscription {
  return { id, status, metadata } as unknown as Stripe.Subscription;
}

async function* listOf(items: Stripe.Subscription[]) {
  for (const item of items) yield item;
}

describe("backfill subscriptions from Stripe", () => {
  const rows = [
    subscription("sub_user", { app: "cmux", stackUserId: "user-1" }),
    subscription("sub_team", { app: "cmux", stackUserId: "user-2", stackTeamId: "team-1" }),
    subscription("sub_other_app", { app: "other" }),
    subscription("sub_founder", { app: "cmux", founders_edition: "true" }, "canceled"),
    subscription("sub_no_metadata", {}),
  ];

  test("dry run counts cmux subscriptions and writes nothing", async () => {
    const applied: string[] = [];
    const lines: string[] = [];
    const result = await backfillSubscriptionsFromStripe({
      list: () => listOf(rows),
      apply: async (row) => {
        applied.push(row.id);
        return { scope: "user" };
      },
      log: (line) => lines.push(line),
    });

    expect(applied).toEqual([]);
    expect(result).toMatchObject({ listed: 5, cmux: 3, applied: 0, skipped: 0, failed: 0 });
    expect(lines.some((line) => line.includes("sub_team") && line.includes("team team-1"))).toBe(true);
  });

  test("apply routes every cmux subscription through the webhook path and reports skips and failures", async () => {
    const applied: string[] = [];
    const result = await backfillSubscriptionsFromStripe({
      apply_mode: "apply",
      list: () => listOf(rows),
      apply: async (row) => {
        applied.push(row.id);
        if (row.id === "sub_founder") return { skipped: true };
        if (row.id === "sub_team") throw new Error("Stack user not found");
        return { scope: "user", stackUserId: "user-1", isActive: true };
      },
    });

    expect(applied).toEqual(["sub_user", "sub_team", "sub_founder"]);
    expect(result).toMatchObject({ listed: 5, cmux: 3, applied: 1, skipped: 1, failed: 1 });
    expect(result.failures).toEqual([{ id: "sub_team", message: "Stack user not found" }]);
  });
});
