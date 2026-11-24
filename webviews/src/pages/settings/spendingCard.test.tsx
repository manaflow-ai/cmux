// Settings > Cloud > Spending's card: it hands every change to its callbacks (no write path exists yet), an
// emptied field is off, a bad amount is refused in place, and the paused banner offers Raise limit and Run on
// This Mac.
import { afterAll, expect, test } from "bun:test";
import type { SpendCap } from "../cloud/spendCap";
import { DEFAULT_SPENDING, type SpendingSettings, spendingModel } from "./spending";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderCard, click, changeValue, fire } = await import("./testing");
const { SpendingCardView } = await import("./components/SpendingCard");

const paused: SpendCap = {
  state: "at_cap",
  spent_usd: 50,
  cap_usd: 50,
  period_end: null,
  checked_at: null,
  pause_at: null,
  paused_at: 1,
};

async function render(settings: SpendingSettings, read: SpendCap | null = null) {
  const limits: (number | null)[] = [];
  const runs: string[] = [];
  const page = await renderCard(
    <SpendingCardView
      model={spendingModel(settings, read, "en")}
      layout="rows"
      onLimitChange={(usd) => limits.push(usd)}
      onAskAboveChange={() => {}}
      onRunOnMac={() => runs.push("mac")}
    />,
  );
  const card = page.container.querySelector<HTMLElement>('[data-card="spending"]')!;
  return { page, card, limits, runs };
}

test("off by default: no field, no banner", async () => {
  const { page, card } = await render(DEFAULT_SPENDING);
  expect(card.querySelector("[data-spending-limit]")).toBeNull();
  expect(card.querySelector("[data-spending-banner]")).toBeNull();
  expect(card.querySelector("[data-spending-ask-above]")?.getAttribute("data-spending-ask-above")).toBe("8x16");
  page.unmount();
});

test("turning on shows the field and sends nothing until an amount is entered", async () => {
  const { page, card, limits } = await render(DEFAULT_SPENDING);
  await click(card.querySelector("[data-spending-overage]")!);
  const field = card.querySelector<HTMLInputElement>("[data-spending-limit]")!;
  expect(field).not.toBeNull();
  expect(limits).toEqual([]);
  await changeValue(field, "40");
  await fire(field, "keydown", { key: "Enter" });
  expect(limits).toEqual([40]);
  page.unmount();
});

test("a bad amount is refused in place; an emptied field is off", async () => {
  const { page, card, limits } = await render({ ...DEFAULT_SPENDING, overage_limit_usd: 50 });
  const field = card.querySelector<HTMLInputElement>("[data-spending-limit]")!;
  await changeValue(field, "-3");
  await fire(field, "keydown", { key: "Enter" });
  expect(card.querySelector("[data-spending-limit-error]")).not.toBeNull();
  expect(limits).toEqual([]);
  await changeValue(field, "");
  await fire(field, "keydown", { key: "Enter" });
  expect(limits).toEqual([null]);
  page.unmount();
});

test("paused at the limit: the banner offers Raise limit and Run on This Mac", async () => {
  const { page, card, runs } = await render({ ...DEFAULT_SPENDING, overage_limit_usd: 50 }, paused);
  const banner = card.querySelector<HTMLElement>('[data-spending-banner="paused"]')!;
  expect(banner.textContent).toContain("Paused at your overage limit");
  const buttons = [...banner.querySelectorAll("button")].map((button) => button.textContent);
  expect(buttons).toContain("Raise limit");
  expect(buttons).toContain("Run on This Mac");
  await click([...banner.querySelectorAll("button")].find((button) => button.textContent === "Run on This Mac")!);
  expect(runs).toEqual(["mac"]);
  page.unmount();
});
