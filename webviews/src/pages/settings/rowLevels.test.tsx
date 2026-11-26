// Rows behind More Options stay reachable: by the keyboard only while they show, and by a link
// (search, the CLI, the palette, MCP) on the page that draws them.
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

test("a link to a key opens its home; an old Personalization link opens the page that draws it now", () => {
  expect(routeSection("notifications", "notifications.sound")).toBe("notifications");
  expect(routeSection("appearance", "appearance.backgroundOpacity")).toBe("appearance");
  // Text Size is drawn by Appearance's density card.
  expect(routeSection("general", "appearance.metrics.chromeFontSize")).toBe("appearance");
  expect(routeSection("general", "app.quitBehavior")).toBe("general");
  expect(routeSection("personalization", "personalization.sounds")).toBe("notifications");
  expect(routeSection("personalization", "personalization.chief")).toBe("chief");
  expect(routeSection("personalization", null)).toBe("appearance");
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

// Leo, 2026-11-19: "just fucking have them be highlights." The active pane highlight color
// (focusRing.color) is on its home page, Tabs and Panes, behind the More Options of the card that
// holds the focus ring rows (Pane Style), and a link to the key opens that page.
test("the active pane highlight color shows on Tabs and Panes under the focus ring card's More Options", async () => {
  expect(routeSection("appearance", "focusRing.color")).toBe("tabs");
  page = await renderPage({ path: "/settings/tabs" });
  const rows = [...page.container.querySelectorAll<HTMLElement>('[data-row-key="focusRing.color"]')];
  expect(rows.length).toBe(1);
  expect(rows[0]!.closest(".more-options-rows")).not.toBeNull();
  const card = rows[0]!.closest("[data-card]");
  expect(card?.querySelector('[data-row-key="focusRing.enabled"]')).not.toBeNull();
});
