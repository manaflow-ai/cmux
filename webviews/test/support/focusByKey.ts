// Focus that a person's key moved (FOCUS-RING, src/ui/focusModality.ts): a ring shows only for focus a
// navigation key moved, so a test that measures a focused control's ring earns its focus this way
// instead of `locator.focus()`, which is code focus and shows none. A real Tab is pressed; its default
// is taken and the target focused from the key's own handler, as tabReach.ts and the menus do.
import type { Locator, Page } from "playwright";

export async function focusByKey(page: Page, target: string | Locator): Promise<void> {
  const element = typeof target === "string" ? page.locator(target).first() : target;
  await element.evaluate((node: HTMLElement) => {
    addEventListener(
      "keydown",
      (event: KeyboardEvent) => {
        if (event.key !== "Tab") return;
        event.preventDefault();
        // Tab arrives from somewhere else: a field that already has focus is left first.
        if (document.activeElement === node) node.blur();
        node.focus();
      },
      { once: true },
    );
  });
  await page.keyboard.press("Tab");
}
