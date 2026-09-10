import { describe, expect, mock, test } from "bun:test";
import { runBillingAlertChecks } from "../services/observability/billingAlerts";
import type { AlertInput } from "../services/observability/alerts";

function recorder() {
  const sent: AlertInput[] = [];
  const sendAlert = mock(async (input: AlertInput) => {
    sent.push(input);
    return { sent: true, configured: true };
  });
  return { sent, sendAlert };
}

describe("billing alert checks", () => {
  test("a webhook processing error in the window pages as critical with the event types", async () => {
    const { sent, sendAlert } = recorder();
    const summary = await runBillingAlertChecks({
      now: new Date("2026-09-10T06:00:00.000Z"),
      sendAlert,
      countWebhookErrors: async () => ({ count: 2, types: ["checkout.session.completed"], latest: "Stack Auth user lookup exceeded its bounded page budget" }),
      countUnsentPurchaseEmails: async () => 0,
    });
    expect(summary.webhookErrors).toEqual({ triggered: true, count: 2 });
    expect(sent).toHaveLength(1);
    expect(sent[0]?.key).toBe("stripe-webhook-errors");
    expect(sent[0]?.severity).toBe("critical");
    expect(sent[0]?.body).toContain("checkout.session.completed");
    expect(sent[0]?.body).toContain("bounded page budget");
  });

  test("unsent purchase emails older than the grace period warn once per run", async () => {
    const { sent, sendAlert } = recorder();
    const summary = await runBillingAlertChecks({
      now: new Date("2026-09-10T06:00:00.000Z"),
      sendAlert,
      countWebhookErrors: async () => ({ count: 0, types: [], latest: null }),
      countUnsentPurchaseEmails: async () => 3,
    });
    expect(summary.unsentPurchaseEmails).toEqual({ triggered: true, count: 3 });
    expect(sent.map((a) => a.key)).toEqual(["purchase-emails-unsent"]);
    expect(sent[0]?.severity).toBe("warning");
  });

  test("a quiet hour sends nothing", async () => {
    const { sent, sendAlert } = recorder();
    const summary = await runBillingAlertChecks({
      now: new Date("2026-09-10T06:00:00.000Z"),
      sendAlert,
      countWebhookErrors: async () => ({ count: 0, types: [], latest: null }),
      countUnsentPurchaseEmails: async () => 0,
    });
    expect(sent).toHaveLength(0);
    expect(summary.webhookErrors.triggered).toBe(false);
    expect(summary.unsentPurchaseEmails.triggered).toBe(false);
  });
});
