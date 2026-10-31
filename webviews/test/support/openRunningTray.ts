import type { Frame, Page } from "playwright";

/// Opens the running tray as the person does. A tray with more than one line starts folded to its
/// header (https://github.com/manaflow-ai/cmux/issues/28875): a click on the header opens it, and the
/// fold's motion is finished so what the test reads is the open list. A tray of one line has no
/// header and is already open.
export async function openRunningTray(page: Page | Frame): Promise<void> {
  const head = page.locator('.acpmux-running-tray__head[aria-expanded="false"]');
  if ((await head.count()) > 0) await head.first().click();
  await page.waitForFunction(() => {
    const tray = document.querySelector(".acpmux-running-tray");
    const head = tray?.querySelector(".acpmux-running-tray__head");
    return (
      Boolean(tray?.querySelector(".acpmux-running-tray__list")) && head?.getAttribute("aria-expanded") !== "false"
    );
  });
  await page.evaluate(() => {
    for (const animation of document.getAnimations())
      if (Number.isFinite(animation.effect?.getComputedTiming().endTime as number)) animation.finish();
  });
}
