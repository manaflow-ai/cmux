import path from "node:path";
import { chromium } from "playwright";
import { createServer } from "vite";

const out = process.env.FAST_CHECKS_OUT ?? "/tmp/devmenu-shots-out";
const webviews = import.meta.dir;
const vite = await createServer({
  configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
  server: { port: 0, host: "127.0.0.1", strictPort: false },
  logLevel: "error",
});
await vite.listen();
const port = (vite.httpServer!.address() as { port: number }).port;
const url = (variant: string) =>
  `http://127.0.0.1:${port}/gallery/frame.html?entry=agent-pane.composer-context&entryPath=src/agent-session/acpmux/ComposerContext.gallery.tsx&variant=${variant}`;
const browser = await chromium.launch({ headless: true });
const open = async (variant: string, height = 520) => {
  const page = await browser.newPage({ viewport: { width: 760, height }, deviceScaleFactor: 2 });
  await page.addInitScript(() => localStorage.setItem("cmux.composer.look", "claude"));
  for (let tries = 0; ; tries++) {
    try {
      await page.goto(url(variant));
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
        timeout: 120000,
      });
      break;
    } catch (error) {
      if (tries > 3) throw error;
    }
  }
  await page.evaluate(() => document.fonts.ready);
  await page.waitForTimeout(600);
  return page;
};
const log: string[] = [];
const state = (page: import("playwright").Page) =>
  page.evaluate(() => ({
    list: !!document.querySelector(".acpmux-env-popover:not(.acpmux-env-cascade)"),
    cascade: !!document.querySelector(".acpmux-env-cascade"),
    chip: document.querySelector(".acpmux-location-button")?.getAttribute("aria-label") ?? null,
    rows: [...document.querySelectorAll(".acpmux-env-popover .acpmux-menu-label")].map((e) => e.textContent),
  }));
for (const variant of [
  "place-auto",
  "place-machine-cascade",
  "place-machine-picked",
  "place-auto-cloud-busy",
  "place-no-own-machines",
  "place-glyph-shipped",
  "place-glyph-steep",
  "place-glyph-upright",
  "place-comparison-drill-in",
]) {
  const page = await open(variant);
  await page.screenshot({ path: `${out}/${variant}.png` });
  log.push(`${variant}: ${JSON.stringify(await state(page))}`);
  await page.close();
}
// Proof: <- goes back one level, the list stays.
{
  const page = await open("place-machine-cascade");
  log.push(`left-before: ${JSON.stringify(await state(page))}`);
  await page.evaluate(() =>
    (
      document.querySelector<HTMLInputElement>(".acpmux-env-cascade input") ??
      (document.querySelector(".acpmux-env-cascade .acpmux-env-row") as HTMLElement | null)
    )?.focus(),
  );
  await page.keyboard.press("ArrowLeft");
  await page.waitForTimeout(500);
  await page.screenshot({ path: `${out}/proof-left-arrow.png` });
  log.push(`left-after: ${JSON.stringify(await state(page))}`);
  await page.close();
}
// Proof: Esc closes the cascade first (list stays), a second Esc closes the list.
{
  const page = await open("place-machine-cascade");
  await page.evaluate(() =>
    (
      document.querySelector<HTMLInputElement>(".acpmux-env-cascade input") ??
      (document.querySelector(".acpmux-env-cascade .acpmux-env-row") as HTMLElement | null)
    )?.focus(),
  );
  await page.keyboard.press("Escape");
  await page.waitForTimeout(500);
  await page.screenshot({ path: `${out}/proof-esc-1.png` });
  log.push(`esc1: ${JSON.stringify(await state(page))}`);
  await page.keyboard.press("Escape");
  await page.waitForTimeout(500);
  await page.screenshot({ path: `${out}/proof-esc-2.png` });
  log.push(`esc2: ${JSON.stringify(await state(page))}`);
  await page.close();
}
// Proof: with the cascade open, a click on the parent's Cloud only row works (the parent is clickable).
{
  const page = await open("place-machine-cascade");
  await page.getByText("Cloud only", { exact: true }).first().click();
  await page.waitForTimeout(600);
  await page.screenshot({ path: `${out}/proof-click-parent.png` });
  log.push(`click-parent: ${JSON.stringify(await state(page))}`);
  await page.close();
}
// Proof: a click outside closes everything.
{
  const page = await open("place-machine-cascade");
  await page.mouse.click(740, 20);
  await page.waitForTimeout(600);
  await page.screenshot({ path: `${out}/proof-click-outside.png` });
  log.push(`click-outside: ${JSON.stringify(await state(page))}`);
  await page.close();
}
await Bun.write(`${out}/proof-log.txt`, log.join("\n") + "\n");
await browser.close();
await vite.close();
