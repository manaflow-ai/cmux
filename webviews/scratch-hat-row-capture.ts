// Scratch, not committed: the `row` arm's click-through in the gallery, light and dark, cropped to the hat.
import { chromium } from "playwright";
import path from "node:path";
import fs from "node:fs";
import { createServer } from "vite";
import { galleryFrame, warmGalleryFrame } from "./test/support/galleryFrame";

const out = path.resolve(process.env.FAST_CHECKS_OUT || process.argv[2] || "hat-row-shots");
fs.mkdirSync(out, { recursive: true });
const ENTRY = "agent-pane.composer-hat-open";
const server = await createServer({
  root: import.meta.dir,
  configFile: path.join(import.meta.dir, "vite.config.gallery-dev.ts"),
  server: { port: 0, host: "127.0.0.1", strictPort: false },
  logLevel: "error",
});
await server.listen();
const port = (server.httpServer!.address() as { port: number }).port;
const browser = await chromium.launch({ headless: true });
await warmGalleryFrame(server, ENTRY, { browser, params: { variant: "row-open" } });
const report: Record<string, unknown> = {};
try {
  for (const theme of ["light", "dark"]) {
    const page = await browser.newPage({ viewport: { width: 760, height: 560 }, deviceScaleFactor: 2 });
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: "row-open", colorScheme: theme, exp: "composer-hat-open", arm: "row" })}`,
    );
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    const tray = page.locator(".acpmux-running-tray");
    const shot = async (name: string) => {
      await page.waitForTimeout(450);
      const box = (await tray.boundingBox())!;
      await page.screenshot({
        path: path.join(out, `${name}-${theme}.png`),
        clip: { x: box.x - 8, y: box.y - 8, width: box.width + 16, height: box.height + 16 },
      });
    };
    const lines = page.locator(".acpmux-running-tray__list .acpmux-agent-line");
    const bg = (i: number) => lines.nth(i).evaluate((n) => getComputedStyle(n).backgroundColor);
    // 2. Hover a row.
    await lines.nth(1).locator(".acpmux-agent-line__button").hover();
    await shot("2-row-hover");
    report[`${theme}.rowHoverLineBg`] = await bg(1);
    // 5. The chevron: the pointer moves from the row onto it, then presses it.
    await lines.nth(1).locator(".acpmux-agent-line__disclose").hover();
    await page.waitForTimeout(450);
    report[`${theme}.chevronHoverLineBg`] = await bg(1);
    report[`${theme}.chevronHoverPopupOpen`] = await lines
      .nth(1)
      .locator(".acpmux-agent-line__button")
      .evaluate((n) => n.hasAttribute("data-popup-open"));
    await shot("5a-chevron-hover");
    await lines.nth(1).locator(".acpmux-agent-line__disclose").click();
    await shot("5b-chevron-details");
    report[`${theme}.detailsExpanded`] = await lines
      .nth(1)
      .locator(".acpmux-agent-line__disclose")
      .getAttribute("aria-expanded");
    await lines.nth(1).locator(".acpmux-agent-line__disclose").click();
    // 7. Keyboard: focus walks row, details, next row; Enter on the row opens it.
    await page.mouse.move(2, 2);
    await lines.nth(0).locator(".acpmux-agent-line__button").focus();
    const order: string[] = [];
    for (let i = 0; i < 4; i++) {
      order.push(
        await page.evaluate(() => {
          const a = document.activeElement as HTMLElement | null;
          return a ? `${a.className.split(" ")[0]}${a.getAttribute("aria-label") ? `[${a.getAttribute("aria-label")}]` : ""}` : "none";
        }),
      );
      if (i === 0) await shot("7a-keyboard-row-focus");
      if (i === 1) await shot("7b-keyboard-details-focus");
      await page.keyboard.press("Tab");
    }
    report[`${theme}.tabOrder`] = order;
    await lines.nth(0).locator(".acpmux-agent-line__button").focus();
    await page.keyboard.press("Enter");
    await page.waitForTimeout(600);
    report[`${theme}.afterEnterTrayStillThere`] = await page.locator(".acpmux-running-tray__list").count();
    report[`${theme}.afterEnterText`] = (await page.locator("body").innerText()).slice(0, 300);
    await page.screenshot({ path: path.join(out, `3-row-click-opens-${theme}.png`) });
    await page.close();
  }
} finally {
  console.log(`REPORT ${JSON.stringify(report, null, 1)}`);
  // The fleet keeps no output files: each shot goes back through the log.
  for (const name of fs.readdirSync(out).filter((n) => n.endsWith(".png")))
    console.log(`PNGB64 ${name} ${fs.readFileSync(path.join(out, name)).toString("base64")}`);
  await browser.close();
  await server.close();
}
