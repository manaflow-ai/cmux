// The Settings page reads in sections (user 2026-10-30: "refactoring the settings page to look a lot
// better with sections"): the sidebar is six pages, the layout the Swift
// `SettingsPageLayout.sidebarSections` exports, and no card is a wall of rows.
import { afterAll, afterEach, expect, test } from "bun:test";
import { act } from "react";
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
    header: section.querySelector(".sidebar-section-title, .sidebar-more-label")?.textContent ?? null,
    links: [...section.querySelectorAll("[data-section-link]")].map((link) => link.getAttribute("data-section-link")!),
  }));
}

test("the sidebar sections hold every category once, in category order", () => {
  expect(sidebarSections.flatMap((section) => section.categories)).toEqual(categories.map((category) => category.id));
  // Six pages (one settings area, findings G6; Leo 2026-11-22: "ay, fuck it we ball"), every one titled
  // and none drawn closed.
  expect(sidebarSections.map((section) => section.id)).toEqual([
    "general",
    "appearance",
    "ai",
    "devices",
    "keyboard",
    "advanced",
  ]);
  expect(sidebarSections.every((section) => section.title !== null)).toBe(true);
  expect(sidebarSections.some((section) => section.collapsed)).toBe(false);
});

test("no card holds more than 16 rows", () => {
  const long = categories.flatMap((category) =>
    category.groups.filter((group) => group.rows.length > 16).map((group) => `${category.id}/${group.key}`),
  );
  expect(long).toEqual([]);
});

test("the sidebar draws six page links, and the shown page's categories under its link", async () => {
  page = await renderPage({ path: "/settings/agents" });
  const container = page.container;
  // Each page's link is its first category's, under the page's title.
  const pages = [...container.querySelectorAll<HTMLElement>("[data-sidebar-page]")];
  expect(pages.map((link) => [link.dataset.sidebarPage, link.dataset.sectionLink, link.textContent])).toEqual([
    ["general", "general", "General"],
    ["appearance", "appearance", "Appearance"],
    ["ai", "chat", "AI"],
    ["devices", "accounts", "Accounts and Devices"],
    ["keyboard", "keyboard", "Keyboard"],
    ["advanced", "advanced", "Advanced"],
  ]);
  // Every category is in the sidebar once; a closed page's other categories are inert.
  expect(sidebar(container).flatMap((section) => section.links)).toEqual(categories.map((category) => category.id));
  const children = (id: string) =>
    container.querySelector(`[data-sidebar-section="${id}"] .sidebar-page-children`) as HTMLElement;
  expect(children("ai").hasAttribute("data-open")).toBe(true);
  expect(children("ai").hasAttribute("inert")).toBe(false);
  expect(children("general").hasAttribute("data-open")).toBe(false);
  expect(children("general").hasAttribute("inert")).toBe(true);
  expect(container.querySelector('[data-sidebar-page="ai"]')!.hasAttribute("data-open")).toBe(true);
  expect(container.querySelector('[data-section-link="agents"]')!.getAttribute("aria-current")).toBe("page");
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

test("a click on the category already shown takes its page back to the top; another category does not", async () => {
  page = await renderPage({ path: "/settings/general" });
  const content = page.container.querySelector<HTMLElement>(".content")!;
  const tops: number[] = [];
  content.scrollTo = ((options: ScrollToOptions) => void tops.push(options.top ?? -1)) as typeof content.scrollTo;
  await act(async () => page!.container.querySelector<HTMLElement>('[data-section-link="general"]')!.click());
  expect(tops).toEqual([0]);
  await act(async () => page!.container.querySelector<HTMLElement>('[data-section-link="updates"]')!.click());
  expect(tops).toEqual([0]);
});
