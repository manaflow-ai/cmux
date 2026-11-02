// Leo 2026-10-30, on Settings > Updates: "look for wastage". A group title never repeats its page's
// title (leo-workspace design/settings.md): Updates drew "Updates" as its page title and again as
// its first group's, then "Updates: Advanced". Search results keep each group's whole title, since
// there the title is the only thing that says which page a row is from.
import { afterAll, afterEach, expect, test } from "bun:test";
import { installDom } from "./testDom";
import { shownGroupTitle } from "./components/GroupList";

const restore = installDom();
afterAll(() => restore());
const { changeValue, renderPage, settle } = await import("./testing");

let page: Awaited<ReturnType<typeof renderPage>> | undefined;
afterEach(() => {
  page?.unmount();
  page = undefined;
});

const groupTitles = (root: Element | null) =>
  [...(root?.querySelectorAll("section.group[data-group] .group-title") ?? [])].map((title) => title.textContent);

test("a group title that is its page's title is not drawn; one that starts with it drops the prefix", () => {
  expect(shownGroupTitle("Updates", "Updates")).toBe("");
  expect(shownGroupTitle(" updates ", "Updates")).toBe("");
  expect(shownGroupTitle("Updates: Advanced", "Updates")).toBe("Advanced");
  expect(shownGroupTitle("Updates：Advanced", "Updates")).toBe("Advanced");
  // Only a whole word and a colon are a prefix; another title is left alone.
  expect(shownGroupTitle("Updates Channel", "Updates")).toBe("Updates Channel");
  expect(shownGroupTitle("Updatesmith: x", "Updates")).toBe("Updatesmith: x");
  expect(shownGroupTitle("Window", "General")).toBe("Window");
  // No page title (search results): the whole title.
  expect(shownGroupTitle("Updates", undefined)).toBe("Updates");
});

test("Settings > Updates draws its title once and its advanced group as Advanced", async () => {
  page = await renderPage({ path: "/settings/updates" });
  await settle();
  const section = page.container.querySelector('[data-section="updates"]');
  expect(section?.querySelector(".section-title")?.textContent).toBe("Updates");
  expect(groupTitles(section)).toEqual(["Advanced"]);
  // The rows stay, in their groups.
  expect(
    section?.querySelector('[data-group="settings.group.updates"] [data-row-key="updates.channel"]'),
  ).not.toBeNull();
  expect(section?.querySelector('[data-row-key="updates.idleInstallQuietSeconds"]')).not.toBeNull();
});

test("no category page draws a group title that is its own title", async () => {
  page = await renderPage({ path: "/settings/general" });
  const { categories } = await import("./categories");
  const { text } = await import("./strings");
  for (const category of categories.filter((c) => !c.devOnly)) {
    page.unmount();
    page = await renderPage({ path: `/settings/${category.id}` });
    await settle();
    const title = text(category.title).toLocaleLowerCase();
    const titles = groupTitles(page.container.querySelector(`[data-section="${category.id}"]`));
    expect({ page: category.id, repeats: titles.filter((t) => t?.toLocaleLowerCase() === title) }).toEqual({
      page: category.id,
      repeats: [],
    });
  }
});

test("search results keep a group's whole title", async () => {
  page = await renderPage({ path: "/settings/general" });
  await changeValue(page.container.querySelector<HTMLInputElement>("[data-settings-search]")!, "update channel");
  await settle();
  expect(groupTitles(page.container.querySelector("[data-search-results]"))).toContain("Updates");
});
