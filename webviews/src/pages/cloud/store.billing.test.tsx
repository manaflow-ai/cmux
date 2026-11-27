import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { Strings } from "../shared/i18n";
import { pastDue } from "./account";
import { AccountPanel } from "./AccountPanel";
import { MockCloudProvider } from "./mockProvider";
import { ACTION_RUN, CloudActions, CloudOps } from "./ops";
import { CloudStore } from "./store";

// New-user journeys, 2026-11-23: a Pro user whose renewal failed saw nothing on the Mac; the web
// dashboard showed `banners.pastDue`. The Cloud page now reads the app's `cmux.cloud.billing.status`
// (cmux.com `paymentPastDue`) and shows one line under the plan with Manage Billing.

const settle = async () => {
  for (let i = 0; i < 20; i++) await Promise.resolve();
};

const strings: Strings = {
  language: "en",
  t: (key) =>
    ({
      "plan.pastDue": "Your latest payment failed. Update your payment method to keep your plan active.",
      "plan.manageBilling": "Manage Billing",
    })[key] ?? key,
  format: (key) => key,
};

async function open(provider: MockCloudProvider) {
  const store = new CloudStore(provider);
  const unsubscribe = store.subscribe(() => undefined);
  await settle();
  return { store, unsubscribe };
}

const billingReads = (provider: MockCloudProvider) =>
  provider.calls.filter((call) => call.op === CloudOps.billingStatus).length;

const panel = (store: CloudStore) =>
  renderToStaticMarkup(<AccountPanel store={store} state={store.getSnapshot()} strings={strings} />);

test("only a JSON true is a failed payment", () => {
  expect(pastDue({ payment_past_due: true })).toBe(true);
  expect(pastDue({ payment_past_due: false })).toBe(false);
  expect(pastDue({})).toBe(false);
  expect(pastDue(null)).toBe(false);
  expect(pastDue(undefined)).toBe(false);
  expect(pastDue({ payment_past_due: "true" as unknown as boolean })).toBe(false);
});

test("a failed renewal shows the line and Manage Billing under the plan", async () => {
  const provider = new MockCloudProvider();
  provider.paymentPastDue = true;
  const { store, unsubscribe } = await open(provider);
  expect(store.getSnapshot().paymentPastDue).toBe(true);
  const html = panel(store);
  expect(html).toContain("Your latest payment failed. Update your payment method to keep your plan active.");
  expect(html).toContain("Manage Billing");
  expect(html.indexOf("cloud-plan-name")).toBeLessThan(html.indexOf("cloud-past-due"));
  unsubscribe();
});

test("a paid renewal, a missing field and a failed read show nothing", async () => {
  for (const answer of [false, "fail"] as const) {
    const provider = new MockCloudProvider();
    provider.paymentPastDue = answer;
    const { store, unsubscribe } = await open(provider);
    expect(store.getSnapshot().paymentPastDue).toBe(false);
    expect(panel(store)).not.toContain("cloud-past-due");
    unsubscribe();
  }
  // A host that does not serve the op (an older app) answers an unknown op.
  const older = new MockCloudProvider({ unsupported: [CloudOps.billingStatus] });
  older.paymentPastDue = true;
  const { store, unsubscribe } = await open(older);
  expect(store.getSnapshot().paymentPastDue).toBe(false);
  unsubscribe();
});

test("signed out, the page reads no billing state and shows no line", async () => {
  const provider = new MockCloudProvider({ signedIn: false });
  provider.paymentPastDue = true;
  const { store, unsubscribe } = await open(provider);
  await store.refreshBilling();
  expect(billingReads(provider)).toBe(0);
  expect(store.getSnapshot().paymentPastDue).toBeFalsy();
  unsubscribe();
});

test("a sign-out clears the line", async () => {
  const provider = new MockCloudProvider();
  provider.paymentPastDue = true;
  const { store, unsubscribe } = await open(provider);
  expect(store.getSnapshot().paymentPastDue).toBe(true);
  provider.setSignedIn(false);
  await settle();
  expect(store.getSnapshot().paymentPastDue).toBeFalsy();
  expect(panel(store)).not.toContain("cloud-past-due");
  unsubscribe();
});

test("showing the page again reads the billing state again: a payment made meanwhile hides the line", async () => {
  const provider = new MockCloudProvider();
  provider.paymentPastDue = true;
  const { store, unsubscribe } = await open(provider);
  expect(billingReads(provider)).toBe(1);
  provider.paymentPastDue = false;
  await store.refreshBilling();
  expect(billingReads(provider)).toBe(2);
  expect(store.getSnapshot().paymentPastDue).toBe(false);
  // A failed read on the way back hides it too, rather than showing a stale notice.
  provider.paymentPastDue = true;
  await store.refreshBilling();
  expect(store.getSnapshot().paymentPastDue).toBe(true);
  provider.paymentPastDue = "fail";
  await store.refreshBilling();
  expect(store.getSnapshot().paymentPastDue).toBe(false);
  unsubscribe();
});

test("Manage Billing runs the app's billing.openPortal action", async () => {
  const provider = new MockCloudProvider();
  provider.paymentPastDue = true;
  const { store, unsubscribe } = await open(provider);
  await store.manageBilling();
  expect(provider.billingPortalOpens).toBe(1);
  expect(
    provider.calls.some(
      (call) => call.op === ACTION_RUN && (call.params as { action?: string }).action === CloudActions.manageBilling,
    ),
  ).toBe(true);
  expect(store.getSnapshot().error).toBeUndefined();
  unsubscribe();
});
