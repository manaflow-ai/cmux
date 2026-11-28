// Settings > Cloud > Compute (labs.teamCompute). Off by default, the card draws nothing and reads
// nothing; on, it reads `cmux.settings.cloud.allotment.get` once and draws the Ledger layout, each
// member by display name, with only the team's hold to change (`.set {person_hold_seconds}`: the read
// again after it applied, the server's sentence when it refused), and a plain line when the read
// answers nothing.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { mockAllotments } from "./mockAllotments";
import { rowsByKey, schema, type SchemaRow } from "./schema";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderCard, click } = await import("./testing");
const { CloudComputeCard } = await import("./components/CloudComputeCard");
const { TEAM_COMPUTE_LAB } = await import("./computeAllotment");

/** The Labs row in the page's schema when the checked-in export (settings-schema.json, regenerated on
 * a Mac) does not have it yet, shaped like the other Labs toggles; a no-op once the export lists it. */
beforeAll(() => {
  if (rowsByKey.has(TEAM_COMPUTE_LAB)) return;
  const like = schema.rows.find(
    (row) => row.section === "advanced" && row.kind === "toggle" && row.key.startsWith("labs."),
  );
  if (!like) throw new Error("no Labs toggle to copy");
  const row: SchemaRow = {
    ...structuredClone(like),
    key: TEAM_COMPUTE_LAB,
    path: ["labs", "teamCompute"],
    default: false,
    title: { key: "settings.labs.teamCompute", text: "Team Compute" },
    help: {
      key: "settings.labs.teamCompute.help",
      text: "Show your team's compute allotment and each member's use in Settings > Cloud.",
    },
  };
  schema.rows.push(row);
  (rowsByKey as Map<string, SchemaRow>).set(row.key, row);
});

const on = { mock: { values: { [TEAM_COMPUTE_LAB]: true } } };
const card = (container: HTMLElement) => container.querySelector<HTMLElement>('[data-card="compute"]');
const reads = (log: Array<{ op: string }>) =>
  log.filter((call) => call.op.startsWith("cmux.settings.cloud.allotment.")).map((call) => call.op);

test("off by default the card draws nothing and reads nothing", async () => {
  const page = await renderCard(<CloudComputeCard />);
  expect(card(page.container)).toBeNull();
  expect(page.container.textContent).toBe("");
  expect(reads(page.provider.log)).toEqual([]);
  page.unmount();
});

test("on, it draws each member by display name, read-only", async () => {
  const page = await renderCard(<CloudComputeCard />, {
    ...on,
    setup: (provider) => {
      provider.allotment = { ...structuredClone(mockAllotments.proposalUp), names: { Austin: "Austin Example" } };
    },
  });
  const element = card(page.container)!;
  expect(element).not.toBeNull();
  expect(element.dataset.computeLayout).toBe("ledger");
  expect(reads(page.provider.log)).toEqual(["cmux.settings.cloud.allotment.get"]);
  const members = [...element.querySelectorAll("tbody tr")].map((row) => row.getAttribute("data-compute-member"));
  expect(members).toEqual(["Leo", "Lawrence", "Austin", "Agents: CI", "Agents: lanes", "Aziz", "Sam", "spares"]);
  // A display name where the view has one, the id where it has none.
  expect(element.querySelector('[data-compute-member="Austin"] td')!.textContent).toContain("Austin Example");
  expect(element.querySelector('[data-compute-member="Leo"] td')!.textContent).toContain("Leo");
  expect(element.querySelector("[data-compute-sentence]")!.textContent).toBe(
    "Austin Example passed the allotment 4 times: scaling up costs $40 a month.",
  );
  // Nothing to click that the app cannot answer: no dial, no Auto switch; the hold is the one change.
  expect(element.querySelector("button[data-proposed], [data-compute-option], [data-compute-auto]")).toBeNull();
  expect(element.querySelector("[data-compute-allotment]")!.textContent).toBe("Allotment $300 a month");
  page.unmount();
});

test("on, a read that answers nothing draws one plain line", async () => {
  const page = await renderCard(<CloudComputeCard />, {
    ...on,
    setup: (provider) => {
      provider.allotment = null;
    },
  });
  const element = card(page.container)!;
  expect(element.hasAttribute("data-compute-unavailable")).toBe(true);
  expect(element.textContent).toContain("isn't available");
  expect(element.querySelector("button")).toBeNull();
  page.unmount();
});

const holdOption = (element: HTMLElement, seconds: string) =>
  element.querySelector<HTMLButtonElement>(`[data-compute-hold-option="${seconds}"]`)!;
const pressedHold = (element: HTMLElement) =>
  element.querySelector('[data-compute-hold-option][aria-pressed="true"]')?.getAttribute("data-compute-hold-option");

test("on, the team's hold is Off, 5, 15 or 30 minutes; a click sets it and reads the view again", async () => {
  const page = await renderCard(<CloudComputeCard />, {
    ...on,
    setup: (provider) => {
      provider.allotment = structuredClone(mockAllotments.hold);
    },
  });
  const element = card(page.container)!;
  expect(element.querySelector('[data-compute-hold="choices"]')).not.toBeNull();
  const labels = [...element.querySelectorAll("[data-compute-hold-option]")].map((button) => button.textContent);
  expect(labels).toEqual(["Off", "5 min", "15 min", "30 min"]);
  expect(pressedHold(element)).toBe("off");

  await click(holdOption(element, "900"));
  expect(page.provider.allotmentRuns).toEqual([{ person_hold_seconds: 900 }]);
  expect(reads(page.provider.log)).toEqual([
    "cmux.settings.cloud.allotment.get",
    "cmux.settings.cloud.allotment.set",
    "cmux.settings.cloud.allotment.get",
  ]);
  expect(pressedHold(element)).toBe("900");
  expect(element.querySelector("[data-compute-ready-line]")!.textContent).toContain("15 minutes");
  expect(element.querySelector('[role="alert"]')).toBeNull();

  // Off clears the team's hold.
  await click(holdOption(element, "off"));
  expect(page.provider.allotmentRuns).toEqual([{ person_hold_seconds: 900 }, { person_hold_seconds: null }]);
  expect(page.provider.allotment?.allotment && "person_hold_seconds" in page.provider.allotment.allotment).toBe(false);
  expect(pressedHold(element)).toBe("off");
  page.unmount();
});

test("on, a refused hold shows the server's sentence and keeps the hold as it was", async () => {
  const page = await renderCard(<CloudComputeCard />, {
    ...on,
    setup: (provider) => {
      provider.allotment = structuredClone(mockAllotments.hold);
      provider.allotmentSetRefusal = "Only a team admin can change this.";
    },
  });
  const element = card(page.container)!;
  await click(holdOption(element, "300"));
  expect(page.provider.allotmentRuns).toEqual([{ person_hold_seconds: 300 }]);
  expect(reads(page.provider.log)).toEqual(["cmux.settings.cloud.allotment.get", "cmux.settings.cloud.allotment.set"]);
  expect(element.querySelector('[role="alert"]')!.textContent).toBe("Only a team admin can change this.");
  expect(pressedHold(element)).toBe("off");
  expect(page.provider.allotment?.allotment?.person_hold_seconds).toBeUndefined();

  // The next click that applies clears the line.
  page.provider.allotmentSetRefusal = null;
  await click(holdOption(element, "1800"));
  expect(element.querySelector('[role="alert"]')).toBeNull();
  expect(pressedHold(element)).toBe("1800");
  page.unmount();
});
