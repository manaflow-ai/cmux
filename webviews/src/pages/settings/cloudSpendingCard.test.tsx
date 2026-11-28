// Settings > Cloud > Spending's live card (the app's `cmux.cloud.spendingWrite`, default off). Off, the app refuses
// `cmux.settings.cloud.spending.state` and the card draws nothing and saves nothing; on, the overage limit saves as
// `cmux.settings.cloud.spending.set {overage_usd, key}` and the card shows the app's words for a refusal.
import { afterAll, expect, test } from "bun:test";
import type { SpendingSaveOutcome } from "./ops";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderCard, click, changeValue, fire } = await import("./testing");
const { CloudSpendingCard } = await import("./components/CloudSpendingCard");

const card = (container: HTMLElement) => container.querySelector<HTMLElement>('[data-card="spending"]');

async function enter(element: HTMLElement, amount: string) {
  const field = element.querySelector<HTMLInputElement>("[data-spending-limit]")!;
  await changeValue(field, amount);
  await fire(field, "keydown", { key: "Enter" });
}

test("off by default the card draws nothing and saves nothing", async () => {
  const page = await renderCard(<CloudSpendingCard />);
  expect(card(page.container)).toBeNull();
  expect(page.container.textContent).toBe("");
  expect(page.provider.spendingSaves).toEqual([]);
  page.unmount();
});

test("on, a limit saves once with its amount and a key", async () => {
  const page = await renderCard(<CloudSpendingCard />, {
    setup: (provider) => {
      provider.spending = (save) => ({ kind: "saved", overageUsd: save.overage_usd, teamCapUsd: 90 });
    },
  });
  const element = card(page.container)!;
  expect(element).not.toBeNull();
  await click(element.querySelector("[data-spending-overage]")!);
  await enter(element, "40");
  expect(page.provider.spendingSaves.map((save) => save.overage_usd)).toEqual([40]);
  expect(page.provider.spendingSaves[0]!.key.length).toBeGreaterThan(0);
  expect(element.querySelector('[role="alert"]')).toBeNull();
  expect(element.querySelector<HTMLInputElement>("[data-spending-limit]")!.value).toBe("40");
  page.unmount();
});

test("on, a refusal shows the app's sentence, and a retry of the same amount keeps its key", async () => {
  const outcome: SpendingSaveOutcome = {
    kind: "refused",
    code: "owner.unreachable",
    message: "Couldn't reach Cloud. Try again.",
    retry: true,
  };
  const page = await renderCard(<CloudSpendingCard />, {
    setup: (provider) => {
      provider.spending = () => outcome;
    },
  });
  const element = card(page.container)!;
  await click(element.querySelector("[data-spending-overage]")!);
  await enter(element, "40");
  expect(element.querySelector('[role="alert"]')!.textContent).toBe("Couldn't reach Cloud. Try again.");
  await enter(element, "41");
  await enter(element, "41");
  const [first, second, third] = page.provider.spendingSaves;
  expect(second!.key).not.toBe(first!.key);
  expect(third!.key).toBe(second!.key);
  page.unmount();
});
