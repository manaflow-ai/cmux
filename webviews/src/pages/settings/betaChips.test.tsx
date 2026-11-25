// Beta chips (Taste Board #15, appearance.settingsBetaChips): off by default the page draws no
// chip anywhere; on, experimental rows (the Experimental page, labs.* keys, rows tagged labs or
// experimental) and the Experimental sidebar entry get one, and no other row does.
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";
import { BETA_CHIPS_KEY, isExperimentalRow } from "./betaChips";
import { categoryRows } from "./categories";
import { rowsByKey, schema } from "./schema";

const restore = installDom();
afterAll(() => restore());
const { renderPage, rowElement, settle } = await import("./testing");

const chipOf = (container: ParentNode, key: string) =>
  rowElement(container, key).querySelector(".row-title [data-beta-chip]");
const sidebarChip = (container: ParentNode, category: string) =>
  container.querySelector(`[data-section-link="${category}"] [data-beta-chip]`);

test("the opt-in is a toggle, off by default, on the Experimental page", () => {
  const row = rowsByKey.get(BETA_CHIPS_KEY);
  expect(row?.kind).toBe("toggle");
  expect(row?.default).toBe(false);
  expect(categoryRows("experimental").map((r) => r.key)).toContain(BETA_CHIPS_KEY);
});

test("experimental rows are the Experimental page, labs.* keys and rows tagged labs or experimental", () => {
  const experimental = schema.rows.filter(isExperimentalRow).map((row) => row.key);
  expect(experimental).toContain("appearance.experimentalControls");
  expect(experimental).toContain("labs.previewFeatures");
  expect(experimental).toContain("labs.liveCode");
  // A beta update ring is not an experiment; nor is an everyday row.
  expect(experimental).not.toContain("updates.channel");
  expect(experimental).not.toContain("appearance.theme");
  expect(isExperimentalRow({ key: "x.y", keywords: ["beta"] })).toBe(false);
  expect(isExperimentalRow({ key: "x.y", keywords: ["labs"] })).toBe(true);
});

test("off (the default): no chip on any row or sidebar entry", async () => {
  for (const path of ["/settings/experimental", "/settings/updates"]) {
    const page = await renderPage({ path });
    expect(page.container.querySelector("[data-beta-chip]")).toBeNull();
    page.unmount();
  }
});

test("on: experimental rows and the Experimental sidebar entry get a Beta chip, other rows do not", async () => {
  const labs = await renderPage({ path: "/settings/experimental", mock: { values: { [BETA_CHIPS_KEY]: true } } });
  expect(chipOf(labs.container, "appearance.experimentalControls")?.textContent).toBe("Beta");
  expect(chipOf(labs.container, BETA_CHIPS_KEY)).not.toBeNull();
  expect(chipOf(labs.container, "labs.previewFeatures")).not.toBeNull();
  expect(sidebarChip(labs.container, "experimental")?.textContent).toBe("Beta");
  expect(sidebarChip(labs.container, "general")).toBeNull();
  expect(labs.container.querySelectorAll("[data-section-link] [data-beta-chip]").length).toBe(1);
  labs.unmount();

  const general = await renderPage({ path: "/settings/updates", mock: { values: { [BETA_CHIPS_KEY]: true } } });
  expect(chipOf(general.container, "updates.channel")).toBeNull();
  general.unmount();
});

test("turning it on live draws the chips without a reload", async () => {
  const page = await renderPage({ path: "/settings/experimental" });
  expect(page.container.querySelector("[data-beta-chip]")).toBeNull();
  await page.store.set(BETA_CHIPS_KEY, true);
  await settle();
  expect(chipOf(page.container, "appearance.experimentalControls")).not.toBeNull();
  page.unmount();
});
