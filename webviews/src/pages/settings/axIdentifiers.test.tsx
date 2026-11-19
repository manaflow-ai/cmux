// An agent drives the Settings page through the accessibility tree, where WebKit reports a DOM `id`
// as the element's AX identifier (`data-*` attributes are not visible there), to use the app as a
// person would (Leo 2026-11-19). Each section link is `settings-section-<id>` and each setting row
// `setting-<key>`, unique on the page.
import { afterAll, afterEach, expect, test } from "bun:test";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { changeValue, renderPage } = await import("./testing");
const { categories } = await import("./categories");

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

/** Every id this change adds, in page order, repeats included. */
const agentIds = (container: ParentNode) =>
  [...container.querySelectorAll("[id]")]
    .map((element) => element.id)
    .filter((id) => id.startsWith("setting-") || id.startsWith("settings-section-"));

const duplicates = (ids: string[]) => ids.filter((id, index) => ids.indexOf(id) !== index);

test("each section link is identified settings-section-<id>", async () => {
  page = await renderPage({ path: "/settings/general" });
  const links = [...page.container.querySelectorAll("[data-section-link]")];
  expect(links.length).toBeGreaterThan(0);
  for (const link of links) {
    expect(link.id).toBe(`settings-section-${link.getAttribute("data-section-link")}`);
  }
});

test("every category's setting rows are identified setting-<key>, once each", async () => {
  for (const category of categories) {
    page = await renderPage({ path: `/settings/${category.id}` });
    const ids = agentIds(page.container);
    expect({ category: category.id, duplicates: duplicates(ids) }).toEqual({ category: category.id, duplicates: [] });
    const keys = new Set(
      [...page.container.querySelectorAll(".content [data-row-key]")].map((row) => row.getAttribute("data-row-key")!),
    );
    for (const key of keys) {
      const row = page.container.querySelector(`[id="setting-${key}"]`);
      expect({ category: category.id, key, found: row?.getAttribute("data-row-key") ?? null }).toEqual({
        category: category.id,
        key,
        found: key,
      });
    }
    page.unmount();
    page = null;
  }
});

test("search results keep one setting-<key> per row", async () => {
  page = await renderPage({ path: "/settings/general" });
  await changeValue(page.container.querySelector<HTMLInputElement>("[data-settings-search]")!, "font");
  const ids = agentIds(page.container);
  expect(duplicates(ids)).toEqual([]);
  expect(ids).toContain("setting-terminal.fontFamily");
});
