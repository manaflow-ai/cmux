// Seven Settings Pages (`appearance.settingsPages`, Settings > Customize, off by default; Leo
// 2026-11-22: "ay, fuck it we ball"; design court dp-d5c2e44ba3 keeps Tools). Off, the page is
// unchanged: titled runs, More, no page crumb, the app theme's own Match System Appearance. On, the
// sidebar is seven pages, a search result's header names its page, and one Match switch drives both themes.
import { afterAll, afterEach, expect, test } from "bun:test";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";
import { SETTINGS_PAGES_KEY } from "./settingsPages";
import { rowsByKey } from "./schema";

const restore = installDom();
afterAll(() => restore());
const { changeValue, click, ops, renderPage } = await import("./testing");
const { categories, settingsPageSections } = await import("./categories");
const { t } = await import("./strings");

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

const ON = { values: { [SETTINGS_PAGES_KEY]: true } };
const themeRow = (page: Rendered, kind: string) =>
  page.container.querySelector<HTMLElement>(`[data-card="theme"] [data-theme-row="${kind}"]`);
const search = (page: Rendered) => page.container.querySelector<HTMLInputElement>("[data-settings-search]")!;
const resultTitle = (page: Rendered, id: string) =>
  page.container.querySelector(`[data-search-results] [data-section="${id}"] .result-section-title`)?.textContent;

test("the opt-in is a toggle, off by default", () => {
  const row = rowsByKey.get(SETTINGS_PAGES_KEY);
  expect(row?.kind).toBe("toggle");
  expect(row?.default).toBe(false);
});

test("the seven pages hold every category once", () => {
  expect(settingsPageSections.map((section) => section.id)).toEqual([
    "general",
    "appearance",
    "ai",
    "devices",
    "keyboard",
    "tools",
    "advanced",
  ]);
  expect(settingsPageSections.every((section) => section.title !== null && !section.collapsed)).toBe(true);
  const placed = settingsPageSections.flatMap((section) => section.categories);
  expect([...placed].sort()).toEqual(categories.map((category) => category.id).sort());
  expect(new Set(placed).size).toBe(placed.length);
});

test("off (the default): titled runs and More, no page links, no crumb, two Match switches", async () => {
  page = await renderPage({ path: "/settings/general" });
  expect(page.container.querySelector("[data-sidebar-page]")).toBeNull();
  expect(page.container.querySelector(".sidebar-more")).not.toBeNull();
  await changeValue(search(page), "font");
  expect(resultTitle(page, "terminal")).toBe("Terminal");
  page.unmount();

  page = await renderPage({ path: "/settings/theme" });
  expect(themeRow(page, "app-match")).not.toBeNull();
});

test("on: seven page links, the shown page's categories open under its link", async () => {
  page = await renderPage({ path: "/settings/agents", mock: ON });
  const container = page.container;
  expect(container.querySelector(".sidebar-more")).toBeNull();
  const pages = [...container.querySelectorAll<HTMLElement>("[data-sidebar-page]")];
  expect(pages.map((link) => [link.dataset.sidebarPage, link.dataset.sectionLink, link.textContent])).toEqual([
    ["general", "general", "General"],
    ["appearance", "appearance", "Appearance"],
    ["ai", "chat", "AI"],
    ["devices", "accounts", "Accounts and Devices"],
    ["keyboard", "keyboard", "Keyboard"],
    ["tools", "terminal", "Tools"],
    ["advanced", "advanced", "Advanced"],
  ]);
  const children = (id: string) =>
    container.querySelector(`[data-sidebar-section="${id}"] .sidebar-page-children`) as HTMLElement;
  expect(children("ai").hasAttribute("data-open")).toBe(true);
  expect(children("ai").hasAttribute("inert")).toBe(false);
  expect(children("general").hasAttribute("inert")).toBe(true);
  expect(container.querySelector('[data-section-link="agents"]')!.getAttribute("aria-current")).toBe("page");
});

test("on: a search result's header is its page then its category", async () => {
  page = await renderPage({ path: "/settings/general", mock: ON });
  await changeValue(search(page), "font");
  expect(resultTitle(page, "terminal")).toBe("Tools › Terminal");
  await changeValue(search(page), "transparency");
  expect(resultTitle(page, "appearance")).toBe("Appearance");
});

test("on: one Match System Appearance sets both theme pairs", async () => {
  page = await renderPage({
    path: "/settings/theme",
    mock: { values: { ...ON.values, "appearance.theme": "Dracula", "appearance.appTheme": "Gruvbox Dark" } },
  });
  expect(themeRow(page, "app-match")).toBeNull();
  expect(page.container.textContent!.split(t("settingsPage.theme.matchSystem")).length).toBe(2);
  await click(themeRow(page, "match")!.querySelector("[role=switch]")!);
  const keys = ops(page.provider, "cmux.settings.set").map((op) => (op as { key: string }).key);
  expect([...keys].sort((x, y) => x.localeCompare(y))).toEqual(["appearance.appTheme", "appearance.theme"]);
});
