import type { Frame, Page } from "playwright";

/// Opens the running tray as the person does. A tray starts folded to its header
/// (https://github.com/manaflow-ai/cmux/issues/28875), one line too (Leo, 2026-11-07: a click on a lone
/// subagent expands the hat rather than opening it): a click on the header opens it, and the fold's
/// motion is finished and settled so what the test reads is the open list.
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
  // A finished fold lets go of its clip in its finish event, after the call above: wait for it, so a
  // focus or a scroll measures the settled tray.
  await page.waitForFunction(() => {
    const fold = document.querySelector<HTMLElement>(".acpmux-running-tray__fold");
    return !fold || fold.style.overflow === "";
  });
}
