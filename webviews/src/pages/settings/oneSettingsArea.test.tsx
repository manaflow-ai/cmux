// One settings area (David Beyer, 2026-11-20: "Personalization and Settings are redundant", and
// Settings felt overwhelming). How cmux looks has one page, Appearance, with no second Personalization
// page or nested sidebar rows beside it; old Personalization links land there. The sidebar's top level
// is short: the everyday pages show, the rest sit under one More that stays closed until opened, and
// search, links and the keyboard still reach every page.
import { afterAll, afterEach, expect, test } from "bun:test";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { click, renderPage } = await import("./testing");
const { categories } = await import("./categories");

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

/** The most category rows the sidebar shows before More is opened. */
const SHORT_TOP_LEVEL = 16;

const shownSection = (container: ParentNode) => container.querySelector("[data-section]")?.getAttribute("data-section");

/** The sidebar links a person sees without opening anything: none inside a closed (inert) region. */
const visibleLinks = (container: ParentNode) =>
  [
    ...container.querySelectorAll<HTMLElement>(".section-list [data-section-link], .section-list [data-part-link]"),
  ].filter((link) => link.closest("[inert]") === null);

test("how cmux looks has one page: Appearance draws the theme, the background and density", async () => {
  page = await renderPage({ path: "/settings/appearance" });
  expect(page.container.querySelector('[data-section-link="personalization"]')).toBeNull();
  expect(page.container.querySelector("[data-part-link]")).toBeNull();
  expect(shownSection(page.container)).toBe("appearance");
  const content = page.container.querySelector(".content")!;
  expect(content.querySelector('[data-card="theme"]')).not.toBeNull();
  expect(content.querySelector('[data-card="backdrop"]')).not.toBeNull();
  expect(content.querySelector('[data-card="density"]')).not.toBeNull();
  // One title: the page's own, not a part's heading beside it.
  expect([...content.querySelectorAll("h1")].map((heading) => heading.textContent)).toEqual(["Appearance"]);
});

test("old Personalization links open Appearance, on the part they named", async () => {
  page = await renderPage({ path: "/settings/personalization" });
  expect(shownSection(page.container)).toBe("appearance");
  page.unmount();
  page = await renderPage({ path: "/settings/personalization?focus=personalization.background&open=1" });
  expect(shownSection(page.container)).toBe("appearance");
  expect(page.container.querySelector('.content [data-card="backdrop"]')).not.toBeNull();
  page.unmount();
  page = await renderPage({ path: "/settings/theme" });
  expect(shownSection(page.container)).toBe("appearance");
});

test("the Chief's look sits on the Chief page", async () => {
  page = await renderPage({ path: "/settings/chief" });
  expect(page.container.querySelector('.content [data-card="chief-pet"]')).not.toBeNull();
});

test("the sidebar's top level is short; the rest sits under More, closed until opened", async () => {
  page = await renderPage({ path: "/settings/general" });
  const shown = visibleLinks(page.container);
  expect(shown.length).toBeLessThanOrEqual(SHORT_TOP_LEVEL);
  const more = page.container.querySelector<HTMLElement>(".sidebar-more")!;
  expect(more).not.toBeNull();
  expect(more.tagName).toBe("BUTTON");
  expect(more.getAttribute("aria-expanded")).toBe("false");
  const region = page.container.querySelector<HTMLElement>(`#${more.getAttribute("aria-controls")}`)!;
  expect(region.hasAttribute("inert")).toBe(true);
  await click(more);
  expect(more.getAttribute("aria-expanded")).toBe("true");
  expect(region.hasAttribute("inert")).toBe(false);
  // Opened, the sidebar lists every page once.
  const all = visibleLinks(page.container).map((link) => link.getAttribute("data-section-link"));
  expect(all).toEqual(categories.map((category) => category.id));
});

test("a page under More opens with More open, its row marked", async () => {
  page = await renderPage({ path: "/settings/devices" });
  const more = page.container.querySelector<HTMLElement>(".sidebar-more")!;
  expect(more.getAttribute("aria-expanded")).toBe("true");
  const current = page.container.querySelector('.section-list [aria-current="page"]');
  expect(current?.getAttribute("data-section-link")).toBe("devices");
  expect(current?.closest("[inert]")).toBeNull();
});
