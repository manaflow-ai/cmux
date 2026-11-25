// Settings > Team > Compute on the mock provider: the card reads `cmux.settings.cloud.allotment.get`
// once, draws each layout from the view-model, and one click sends one `.set` and draws its answer.
import { afterAll, expect, test } from "bun:test";
import { mockAllotments } from "./mockAllotments";
import type { AllotmentView } from "./ops";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderCard, click } = await import("./testing");
const { ComputeCard } = await import("./components/ComputeCard");

type Layout = "ledger" | "meter" | "inbox";
const render = (view: AllotmentView, layout: Layout = "ledger") =>
  renderCard(<ComputeCard layout={layout} />, {
    setup: (provider) => {
      provider.allotment = structuredClone(view);
    },
  });
type Page = Awaited<ReturnType<typeof render>>;
const card = (page: Page) => page.container.querySelector<HTMLElement>('[data-card="compute"]')!;
const option = (page: Page, position: string) =>
  card(page).querySelector<HTMLButtonElement>(
    `[data-compute-option="${position}"] button, button[data-compute-option="${position}"]`,
  )!;

test("the ledger shows the sentence, the proposed position and one row per member plus warm spares", async () => {
  const page = await render(mockAllotments.proposalUp);
  expect(card(page).querySelector("[data-compute-sentence]")?.textContent).toBe(
    "Austin passed the allotment 4 times: scaling up costs $40 a month.",
  );
  expect(option(page, "up").hasAttribute("data-proposed")).toBe(true);
  const members = [...card(page).querySelectorAll("tbody tr")].map((row) => row.getAttribute("data-compute-member"));
  expect(members).toEqual(["Leo", "Lawrence", "Austin", "Agents: CI", "Agents: lanes", "Aziz", "Sam", "spares"]);
  expect(card(page).querySelector('[data-compute-member="spares"]')?.textContent).toContain("Warm spares");
  page.unmount();
});

test("one click applies: Scale up sends one set and draws the answer", async () => {
  const page = await render(mockAllotments.proposalUp);
  await click(option(page, "up"));
  expect(page.provider.allotmentRuns).toEqual([{ action: "up" }]);
  expect(page.provider.allotment?.allotment?.commit_micros).toBe(125_000_000);
  expect(card(page).querySelector("[data-compute-sentence]")?.textContent).toBe(
    "Usage fits the allotment. Nothing to decide.",
  );
  expect(option(page, "hold").hasAttribute("data-proposed")).toBe(true);
  page.unmount();
});

test("the empty team holds with the dial disabled", async () => {
  const page = await render(mockAllotments.empty);
  expect(card(page).querySelector("[data-compute-sentence]")?.textContent).toBe(
    "No one has used Cloud yet. 7 seats include $175 a month. Nothing to decide.",
  );
  for (const position of ["down", "hold", "up"]) expect(option(page, position).disabled).toBe(true);
  expect(card(page).querySelector("[data-compute-table]")).toBeNull();
  page.unmount();
});

test("the meter draws a segment per member who used Cloud and the - / + dial", async () => {
  const page = await render(mockAllotments.proposalDown, "meter");
  const segments = [...card(page).querySelectorAll("[data-compute-segment]")].map((node) =>
    node.getAttribute("data-compute-segment"),
  );
  expect(segments).not.toContain("Sam");
  expect(option(page, "down").textContent).toBe("-");
  expect(option(page, "down").hasAttribute("data-proposed")).toBe(true);
  await click(option(page, "down"));
  expect(page.provider.allotmentRuns).toEqual([{ action: "down" }]);
  page.unmount();
});

test("the inbox's Accept applies its reason and Not now holds", async () => {
  const page = await render(mockAllotments.proposalDown, "inbox");
  expect(card(page).querySelector("[data-compute-hold-line]")?.textContent).toBe("Holding at $300, Auto off");
  await click(card(page).querySelector<HTMLButtonElement>('[data-compute-accept="down"]')!);
  expect(page.provider.allotmentRuns).toEqual([{ action: "down" }]);
  expect(card(page).querySelector("[data-compute-hold-line]")?.textContent).toBe("Holding at $250, Auto off");
  page.unmount();
  const second = await render(mockAllotments.proposalUp, "inbox");
  await click(card(second).querySelector<HTMLButtonElement>("[data-compute-not-now]")!);
  expect(second.provider.allotmentRuns).toEqual([{ action: "hold" }]);
  second.unmount();
});

test("the Auto switch sends only auto and changes only the mode", async () => {
  const page = await render(mockAllotments.proposalUp);
  await click(card(page).querySelector<HTMLElement>('[data-compute-auto] [role="switch"]')!);
  expect(page.provider.allotmentRuns).toEqual([{ auto: true }]);
  expect(page.provider.allotment?.allotment?.mode).toBe("auto");
  expect(page.provider.allotment?.allotment?.snoozed_until).toBeNull();
  page.unmount();
});

test("the meter offers Hold while a proposal waits, and Hold snoozes it", async () => {
  const page = await render(mockAllotments.proposalUp, "meter");
  await click(option(page, "hold"));
  expect(page.provider.allotmentRuns).toEqual([{ action: "hold" }]);
  expect(page.provider.allotment?.allotment?.snoozed_until).not.toBeNull();
  page.unmount();
});
