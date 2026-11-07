import { expect } from "bun:test";
import type { Page } from "playwright";

// Started chats without fork targets still use the list menu.
export const COMPACT_MODEL_MENU = ":is(.acpmux-cols, .acpmux-quick-menu)";
export const OTHER_MODEL_ROW =
  ".acpmux-cols [role=listbox] [role=option]:not([aria-selected=true]):not([aria-disabled=true]), .acpmux-quick-menu [role=menuitemradio]:not([aria-checked=true]):not([data-disabled])";
export const MODEL_ROW_NAME = ":is(.acpmux-cols-name, .acpmux-menu-label)";

/** Columns keep the keyboard in search; list menus focus the row itself. */
export async function highlightOtherModel(page: Page): Promise<string> {
  const columns = (await page.locator(".acpmux-cols").count()) > 0;
  const highlighted = columns ? ".acpmux-cols [role=option][data-hl]" : ".acpmux-quick-menu [role=menuitemradio]";
  const otherIsHighlighted = () =>
    page.evaluate(
      ({ columns, highlighted, other }) => {
        const row = columns ? document.querySelector(highlighted) : document.activeElement;
        return !!row?.matches(other);
      },
      { columns, highlighted, other: OTHER_MODEL_ROW },
    );
  const count = await page
    .locator(columns ? ".acpmux-cols [role=option]" : ".acpmux-quick-menu [role^=menuitem]")
    .count();
  for (let step = 0; step <= count; step++) {
    if (await otherIsHighlighted()) break;
    await page.keyboard.press("ArrowDown");
  }
  expect(await otherIsHighlighted()).toBe(true);
  return page.evaluate(
    ({ columns, highlighted, label }) => {
      const row = columns ? document.querySelector(highlighted) : document.activeElement;
      return row?.querySelector(label)?.textContent ?? "";
    },
    { columns, highlighted, label: MODEL_ROW_NAME },
  );
}

/** A model click in columns holds the pick until the menu closes. */
export async function finishModelClick(page: Page): Promise<void> {
  if (await page.locator(".acpmux-cols:not([data-closed])").count()) {
    expect(await page.evaluate(() => document.activeElement?.matches(".acpmux-cols-search input[type=search]"))).toBe(
      true,
    );
    await page.locator(".acpmux-model .acpmux-picker-button").click();
  }
  await page.locator(COMPACT_MODEL_MENU).first().waitFor({ state: "detached" });
}
