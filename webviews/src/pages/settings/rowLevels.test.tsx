// Rows behind More Options and rows Personalization draws stay reachable: by the keyboard only while
// they show, and by a link (search, the CLI, the palette, MCP) on the page that draws them.
import { afterAll, afterEach, expect, test } from "bun:test";
import { act } from "react";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { fire, renderPage, settle } = await import("./testing");
const { routeSection } = await import("./sectionQueries");
const { APPEARANCE_CATEGORIES } = await import("./appearanceUndo");
const { categories } = await import("./categories");

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

test("a link to a key Personalization draws opens Personalization, from any page", () => {
  expect(routeSection("notifications", "notifications.sound")).toBe("personalization");
  expect(routeSection("appearance", "appearance.backgroundOpacity")).toBe("personalization");
  // Text Size is drawn by the density card there.
  expect(routeSection("appearance", "appearance.metrics.chromeFontSize")).toBe("personalization");
  expect(routeSection("general", "app.quitBehavior")).toBe("general");
});

test("Appearance's undo and reset cover only real categories, never General by fallback", () => {
  const ids = new Set(categories.map((category) => category.id));
  expect(APPEARANCE_CATEGORIES.filter((id) => !ids.has(id))).toEqual([]);
});

test("the rows of a closed More Options are no arrow-key stops", async () => {
  page = await renderPage({ path: "/settings/general", closedMore: true });
  const toggle = page.container.querySelector<HTMLElement>(".more-options")!;
  // Open, then close: the rows stay mounted, inert.
  await act(async () => toggle.click());
  await settle();
  await act(async () => toggle.click());
  await settle();
  const hidden = [...page.container.querySelectorAll<HTMLElement>(".more-options-rows [data-row-key]")];
  expect(hidden.length).toBeGreaterThan(0);
  const rows = [...page.container.querySelectorAll<HTMLElement>(".content [data-row-key]")];
  const before = rows[rows.indexOf(hidden[0]!) - 1]!;
  before.focus();
  await fire(before, "keydown", { key: "ArrowDown" });
  expect(hidden).not.toContain(document.activeElement as HTMLElement);
});
