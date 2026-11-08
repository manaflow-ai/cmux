// The Settings page reads in sections (user 2026-10-30: "refactoring the settings page to look a lot
// better with sections"): the sidebar lists its categories under small headers, the layout the Swift
// `SettingsPageLayout.sidebarSections` exports, and no card is a wall of rows.
import { afterAll, afterEach, expect, test } from "bun:test";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { renderPage } = await import("./testing");
const { categories, sidebarSections } = await import("./categories");

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

/** The sidebar as a person reads it: each section's header (null when untitled), then its links. */
function sidebar(container: ParentNode): Array<{ header: string | null; links: string[] }> {
  return [...container.querySelectorAll("[data-sidebar-section]")].map((section) => ({
    header: section.querySelector(".sidebar-section-title")?.textContent ?? null,
    links: [...section.querySelectorAll("[data-section-link]")].map((link) => link.getAttribute("data-section-link")!),
  }));
}

test("the sidebar sections hold every category once, in category order", () => {
  expect(sidebarSections.flatMap((section) => section.categories)).toEqual(categories.map((category) => category.id));
  expect(sidebarSections[0]!.title).toBeNull();
  expect(sidebarSections.slice(1).every((section) => section.title !== null)).toBe(true);
});

test("no card holds more than 16 rows", () => {
  const long = categories.flatMap((category) =>
    category.groups.filter((group) => group.rows.length > 16).map((group) => `${category.id}/${group.key}`),
  );
  expect(long).toEqual([]);
});

test("the sidebar draws each section's header above its categories", async () => {
  page = await renderPage({ path: "/settings/general" });
  const shown = sidebar(page.container);
  expect(shown[0]).toEqual({ header: null, links: ["general", "updates"] });
  expect(shown.find((section) => section.links.includes("agents"))).toEqual({
    header: "AI",
    links: ["agents", "chief"],
  });
  expect(shown.flatMap((section) => section.links)).toEqual(categories.map((category) => category.id));
  // A header labels its group for VoiceOver and is never a link a click or Tab lands on.
  const header = page.container.querySelector(".sidebar-section-title")!;
  expect(header.closest("a")).toBeNull();
  const group = header.closest("[data-sidebar-section]")!;
  expect(group.getAttribute("role")).toBe("group");
  expect(group.getAttribute("aria-labelledby")).toBe(header.id);
});

test("outside DEV builds Development is gone and its section keeps the rest", async () => {
  page = await renderPage({
    path: "/settings/general",
    setup: (provider) => provider.setHost({ ...provider.host, dev_build: false }),
  });
  const links = sidebar(page.container).flatMap((section) => section.links);
  expect(links).not.toContain("development");
  expect(links).toContain("experimental");
});
