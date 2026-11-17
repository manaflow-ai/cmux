// l10n-allow-file: benchmark output, not shipped UI.
// Scratch diagnostic (STATE_SHOTS=<dir>): screenshots of a prompt row and a reply row at rest, hovered,
// a footer button hovered, focused, pressed, its menu open and closed again, written as PNGs to <dir>.
// compareShots.ts diffs two such dirs pixel by pixel.
import { mkdirSync, writeFileSync } from "node:fs";
import type { Locator, Page } from "playwright";

export async function writeStateShots(page: Page, dir: string) {
  mkdirSync(dir, { recursive: true });
  await page.addStyleTag({ content: "*, *::before, *::after { transition: none !important; animation: none !important; caret-color: transparent !important; }" });
  const shot = async (name: string) => {
    await page.waitForTimeout(250);
    writeFileSync(`${dir}/${name}.png`, await page.screenshot({ animations: "disabled" }));
  };
  const census = await page.evaluate(() =>
    [".acpmux-row", ".cv-user", ".cv-turn-actions", ".cv-message-footer-row", ".cv-message-footer-row button", "[aria-haspopup]"]
      .map((s) => `${s}=${document.querySelectorAll(s).length}`)
      .join(" "),
  );
  console.log(`STATE-SHOTS census ${census}`);
  const rows: [string, string][] = [
    ["user", ".acpmux-row:has(.cv-user .cv-message-footer-row button)"],
    ["reply", ".acpmux-row:has(.cv-turn-actions .cv-message-footer-row button)"],
  ];
  const marks = async () =>
    `${await page.locator("[data-popup-open]").count()} open, ${await page.locator("[data-popup-within]").count()} within`;
  for (const [kind, selector] of rows) {
    const row = page.locator(selector).last();
    if ((await row.count()) === 0) {
      console.log(`STATE-SHOTS no ${kind} row`);
      continue;
    }
    await row.scrollIntoViewIfNeeded();
    await page.mouse.move(2, 2);
    await shot(`${kind}-0-rest`);
    const box = (await row.boundingBox())!;
    await page.mouse.move(box.x + box.width / 2, box.y + 8);
    await shot(`${kind}-1-row-hover`);
    const buttons: Locator = row.locator(".cv-message-footer-row button");
    console.log(`STATE-SHOTS ${kind} footer buttons ${await buttons.count()}`);
    const first = buttons.first();
    await first.hover();
    await shot(`${kind}-2-button-hover`);
    await page.waitForTimeout(1500);
    await shot(`${kind}-3-tooltip-open`);
    console.log(`STATE-SHOTS ${kind} tooltip open: ${await marks()}`);
    const b = (await first.boundingBox())!;
    await page.mouse.move(b.x + b.width / 2, b.y + b.height / 2);
    await page.mouse.down();
    await shot(`${kind}-4-button-pressed`);
    await page.mouse.move(2, 2);
    await page.mouse.up();
    await page.waitForTimeout(800);
    await shot(`${kind}-5-tooltip-closed`);
    console.log(`STATE-SHOTS ${kind} tooltip closed: ${await marks()}`);
    await page.keyboard.press("Shift");
    await first.focus();
    await shot(`${kind}-6-button-focus`);
    await first.blur();
    const more = row.locator("[aria-haspopup='menu']");
    if ((await more.count()) > 0) {
      await more.first().click();
      await shot(`${kind}-7-menu-open`);
      console.log(`STATE-SHOTS ${kind} menu open: ${await marks()}`);
      await page.keyboard.press("Escape");
      await page.mouse.move(2, 2);
      await shot(`${kind}-8-menu-closed`);
      console.log(`STATE-SHOTS ${kind} menu closed: ${await marks()}`);
    }
    await page.mouse.click(box.x + box.width / 2, box.y + 12, { button: "right" });
    await shot(`${kind}-9-context-open`);
    console.log(`STATE-SHOTS ${kind} context open: ${await marks()}`);
    await page.keyboard.press("Escape");
    await page.mouse.move(2, 2);
    await shot(`${kind}-10-context-closed`);
    console.log(`STATE-SHOTS ${kind} context closed: ${await marks()}`);
  }
}
