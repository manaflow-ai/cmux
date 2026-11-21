import { afterAll, afterEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";
import { CUSTOM_DENSITIES_KEY, CUSTOM_DENSITY_KEY, DENSITY_KEY, customDensities, resolve } from "./density";

const restore = installDom();
afterAll(() => restore());
const { changeValue, click, renderPage } = await import("./testing");
let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

const action = (name: string) => page!.container.querySelector<HTMLButtonElement>(`[data-density-action="${name}"]`)!;
const slider = (name: string) =>
  page!.container.querySelector<HTMLInputElement>(`.density-editor input[name="${name}"]`)!;
const preview = () => page!.container.querySelector<HTMLElement>(".density-editor .density-preview")!;

test("a copied preset's exact-size controls update, save and reload the native sizes", async () => {
  page = await renderPage({ path: "/settings/appearance", mock: { values: { [DENSITY_KEY]: "cozy" } } });
  await click(action("duplicate"));
  expect(slider("sidebarRowHeight").value).toBe("30");
  await changeValue(slider("sidebarRowHeight"), "40");
  expect(slider("sidebarRowHeight").value).toBe("40");
  expect(preview().dataset.rowHeight).toBe("40");
  await changeValue(slider("tabHeight"), "38");
  expect(slider("tabHeight").value).toBe("38");
  // The strip is the 38 pt tab plus Default's 5 pt strip padding above and below it (density.ts, #47658).
  expect(preview().style.getPropertyValue("--density-strip")).toBe("calc(48px * var(--page-density, 1))");
  await changeValue(slider("itemCornerRadius"), "3");
  expect(slider("itemCornerRadius").value).toBe("3");
  await changeValue(slider("iconSize"), "20");
  expect(slider("iconSize").value).toBe("20");
  expect(preview().style.getPropertyValue("--density-radius")).toBe("calc(3px * var(--page-density, 1))");
  expect(preview().style.getPropertyValue("--density-icon")).toBe("calc(20px * var(--page-density, 1))");
  await click(action("save"));
  const saved = page.store.getSnapshot().rows.get(CUSTOM_DENSITIES_KEY)!.value;
  const [density] = customDensities(saved);
  expect(resolve(density!)).toMatchObject({ sidebarRowHeight: 40, tabHeight: 38, itemCornerRadius: 3, iconSize: 20 });
  const fixture = JSON.parse(
    readFileSync(
      new URL("../../../../Packages/macOS/CmuxNext/Tests/Fixtures/density-web-edited.json", import.meta.url),
      "utf8",
    ),
  );
  expect(saved).toEqual([fixture]);
  page.unmount();
  page = await renderPage({
    path: "/settings/appearance",
    mock: { values: { [CUSTOM_DENSITIES_KEY]: saved, [CUSTOM_DENSITY_KEY]: density!.id } },
  });
  for (const [name, value] of [
    ["sidebarRowHeight", "40"],
    ["tabHeight", "38"],
    ["itemCornerRadius", "3"],
    ["iconSize", "20"],
  ]) {
    expect(slider(name!).value).toBe(value!);
  }
});

test("a legacy custom row edit does not add preset fill", async () => {
  const legacy = { id: "legacy", name: "Legacy", level: 0, tokens: { sidebarRowHeight: 24 } };
  page = await renderPage({
    path: "/settings/appearance",
    mock: { values: { [CUSTOM_DENSITIES_KEY]: [legacy], [CUSTOM_DENSITY_KEY]: legacy.id } },
  });
  await changeValue(slider("sidebarRowHeight"), "40");
  expect(slider("sidebarRowHeight").value).toBe("40");
  await click(action("save"));
  const [saved] = customDensities(page.store.getSnapshot().rows.get(CUSTOM_DENSITIES_KEY)!.value);
  expect(saved!.tokens?.sidebarRowHeight).toBe(40);
  expect(saved!.tokens?.densityScale).toBeUndefined();
});
