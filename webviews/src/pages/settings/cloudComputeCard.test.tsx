// Settings > Cloud > Compute (labs.teamCompute). Off by default, the card draws nothing and reads
// nothing; on, it reads `cmux.settings.cloud.allotment.get` once and draws the Ledger layout read-only
// (the app serves no `.set`), each member by display name, and a plain line when the read answers nothing.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { mockAllotments } from "./mockAllotments";
import { rowsByKey, schema, type SchemaRow } from "./schema";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderCard } = await import("./testing");
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
  // Nothing to click that the app cannot answer: no dial, no Auto switch.
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
