import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { Strings } from "../shared/i18n";
import { AccountPanel } from "./AccountPanel";
import { MockCloudProvider } from "./mockProvider";
import { ACTION_RUN, CloudActions, CloudOps, type CloudUsage } from "./ops";
import { CloudStore } from "./store";
import { cardBrand, meterAmount } from "./usage";

// Leo, 2026-11-24: billing in the NIGHTLY "at least at the most basic level". The Cloud page shows this month's
// usage and its cost (`cloud.usage.current`, priced by the billing owner) and a button to attach a card.

const settle = async () => {
  for (let i = 0; i < 20; i++) await Promise.resolve();
};

const EN: Record<string, string> = {
  "usage.month": "This month",
  "usage.vcpu": "vCPU",
  "usage.memory": "Memory",
  "usage.stored": "Storage",
  "usage.vcpuHours": "{value} vCPU-h",
  "usage.gibHours": "{value} GiB-h",
  "usage.gibMonths": "{value} GiB-mo",
  "usage.asOf": "As of {time}",
  "usage.gaps": "Some usage is still being counted",
  "usage.testMode": "Test mode",
  "usage.failed": "This month’s usage didn’t load.",
  "payment.add": "Add payment method",
  "payment.card": "{brand} ••{digits}",
  "payment.change": "Change",
  "payment.off": "Payments aren’t open yet",
  "page.retry": "Retry",
};
const strings: Strings = { language: "en", t: (key) => EN[key] ?? key, format: (key) => key };

const usage: CloudUsage = {
  period: "2026-11",
  as_of: Date.UTC(2026, 10, 24, 8, 20),
  metered_since: Date.UTC(2026, 10, 1),
  vcpu_seconds: 10 * 3600,
  memory_gib_seconds: 20 * 3600,
  stored_gib_seconds: 730 * 3600,
  // Deliberately not what the list prices give: the page shows the server's dollars, never its own.
  usd: { vcpu: 0.5, memory: 0.25, stored: 0.125, total: 0.88 },
  gaps: [],
  payment_method: { attached: true, brand: "visa", last4: "4242" },
  stripe_mode: "test",
};

async function open(provider: MockCloudProvider) {
  const store = new CloudStore(provider);
  const unsubscribe = store.subscribe(() => undefined);
  await settle();
  return { store, unsubscribe };
}

const panel = (store: CloudStore) =>
  renderToStaticMarkup(<AccountPanel store={store} state={store.getSnapshot()} strings={strings} />);

test("meters convert seconds to the units they are priced in and keep the server's dollars", () => {
  expect(meterAmount(usage, "vcpu")).toEqual({ amount: 10, usd: 0.5 });
  expect(meterAmount(usage, "memory")).toEqual({ amount: 20, usd: 0.25 });
  expect(meterAmount(usage, "stored")).toEqual({ amount: 1, usd: 0.125 });
  expect(cardBrand("visa")).toBe("Visa");
  expect(cardBrand("amex")).toBe("American Express");
  expect(cardBrand("elo")).toBe("Elo");
  expect(cardBrand(null)).toBeUndefined();
});

test("the panel shows the month's total, each meter, the card and Test mode", async () => {
  const provider = new MockCloudProvider();
  provider.usage = usage;
  const { store, unsubscribe } = await open(provider);
  const html = panel(store);
  expect(html).toContain("This month");
  expect(html).toContain("$0.88");
  expect(html).toContain("10 vCPU-h");
  expect(html).toContain("20 GiB-h");
  expect(html).toContain("1 GiB-mo");
  expect(html).toContain("$0.13");
  expect(html).toContain("Visa ••4242");
  expect(html).toContain("Change");
  expect(html).toContain("Test mode");
  expect(html).not.toContain("Some usage is still being counted");
  expect(html).not.toContain("Add payment method");
  unsubscribe();
});

test("no card shows Add payment method, which runs the checkout through the host", async () => {
  const provider = new MockCloudProvider();
  provider.usage = {
    ...usage,
    payment_method: { attached: false },
    stripe_mode: "live",
    gaps: ["size_unknown"],
  };
  const { store, unsubscribe } = await open(provider);
  const html = panel(store);
  expect(html).toContain("Add payment method");
  expect(html).toContain("Some usage is still being counted");
  expect(html).not.toContain("Test mode");
  await store.addPaymentMethod();
  const checkout = provider.calls.find(
    (call) => call.op === ACTION_RUN && (call.params as { action?: string }).action === CloudOps.billingCheckout,
  );
  expect(checkout).toBeDefined();
  // No plan: the checkout attaches a card and leaves the plan alone.
  expect((checkout?.params as { args?: Record<string, unknown> }).args).not.toHaveProperty("plan");
  unsubscribe();
});

test("payments not open yet replace the button with a note, not an error", async () => {
  const provider = new MockCloudProvider();
  provider.usage = { ...usage, payment_method: { attached: false, brand: null, last4: null } };
  provider.billingOff = true;
  const { store, unsubscribe } = await open(provider);
  await store.addPaymentMethod();
  await settle();
  expect(store.getSnapshot().paymentOff).toBe(true);
  const html = panel(store);
  expect(html).toContain("Payments aren’t open yet");
  expect(html).not.toContain("Add payment method");
  unsubscribe();
});

test("Change opens billing in the browser", async () => {
  const provider = new MockCloudProvider();
  provider.usage = usage;
  const { store, unsubscribe } = await open(provider);
  await store.manageBilling();
  expect(provider.billingPortalOpens).toBe(1);
  expect(
    provider.calls.some(
      (call) => call.op === ACTION_RUN && (call.params as { action?: string }).action === CloudActions.manageBilling,
    ),
  ).toBe(true);
  unsubscribe();
});

test("a failed read shows Retry, and Retry reads it again", async () => {
  const provider = new MockCloudProvider();
  provider.usage = "fail";
  const { store, unsubscribe } = await open(provider);
  expect(store.getSnapshot().usageFailed).toBe(true);
  expect(panel(store)).toContain("This month’s usage didn’t load.");
  provider.usage = usage;
  await store.retryUsage();
  expect(store.getSnapshot().usageFailed).toBe(false);
  expect(panel(store)).toContain("$0.88");
  unsubscribe();
});

test("a server that does not serve it shows no month section and is not read again", async () => {
  const provider = new MockCloudProvider();
  const { store, unsubscribe } = await open(provider);
  expect(store.getSnapshot().unavailable).toContain(CloudOps.usageCurrent);
  expect(panel(store)).not.toContain("cloud-month");
  const reads = provider.calls.filter((call) => call.op === CloudOps.usageCurrent).length;
  await store.refreshBilling();
  expect(provider.calls.filter((call) => call.op === CloudOps.usageCurrent).length).toBe(reads);
  unsubscribe();
});

test("showing the page again reads the usage again", async () => {
  const provider = new MockCloudProvider();
  provider.usage = usage;
  const { store, unsubscribe } = await open(provider);
  provider.usage = { ...usage, usd: { ...usage.usd, total: 1.5 } };
  await store.refreshBilling();
  expect(store.getSnapshot().usage?.usd.total).toBe(1.5);
  unsubscribe();
});
