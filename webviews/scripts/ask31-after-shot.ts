// One-off capture for ask-31a1e4b192: the folded running tray over the composer at feat-cmux-next
// (which carries #62263), its gap above the tray against REST_GAP (56), as PNGs in $FAST_CHECKS_OUT.
import path from "node:path";
import { chromium } from "playwright";
import { createServer } from "vite";
import { galleryFrame, warmGalleryFrame } from "../test/support/galleryFrame";

const ENTRY = "agent-pane.subagent-tray";
const VARIANT = "expand-on-composer";
const out = process.env.FAST_CHECKS_OUT ?? "/tmp/ask31-after";
const root = path.resolve(import.meta.dir, "..");
const server = await createServer({
  root,
  configFile: path.join(root, "vite.config.gallery-dev.ts"),
  server: { port: 0, host: "127.0.0.1", strictPort: false },
  logLevel: "error",
});
await server.listen();
const browser = await chromium.launch({ headless: true });
const results: Record<string, unknown> = {};
try {
  await warmGalleryFrame(server, ENTRY, { browser, params: { variant: VARIANT } });
  const port = (server.httpServer!.address() as { port: number }).port;
  for (const theme of ["dark", "light"] as const) {
    const page = await browser.newPage({ viewport: { width: 760, height: 420 }, deviceScaleFactor: 2, colorScheme: theme });
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: VARIANT, theme })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    const head = page.locator(".acpmux-running-tray__head");
    if ((await head.getAttribute("aria-expanded")) === "true") {
      await head.click();
      await page.waitForFunction(() => !document.querySelector(".acpmux-running-tray__fold"));
    }
    const box = (await page.locator(".acpmux-scroll").boundingBox())!;
    await page.mouse.move(box.x + box.width / 2, box.y + 40);
    await page.mouse.wheel(0, -300);
    await page.waitForFunction(() => {
      const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      return node.scrollHeight - node.clientHeight - node.scrollTop > 100;
    });
    for (let turn = 0; turn < 6; turn++) await page.mouse.wheel(0, 240);
    await page.waitForFunction(() => {
      const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      return node.scrollHeight - node.clientHeight - node.scrollTop <= 2;
    });
    await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(() => r(null)))));
    results[theme] = await page.evaluate(() => {
      const last = [...document.querySelectorAll<HTMLElement>(".acpmux-row")].at(-1)!.getBoundingClientRect();
      const tray = document.querySelector<HTMLElement>(".acpmux-running-tray")!.getBoundingClientRect();
      return { gap: tray.top - last.bottom, lastBottom: last.bottom, trayTop: tray.top };
    });
    await page.screenshot({ path: path.join(out, `after-folded-${theme}.png`) });
    await page.close();
  }
  console.log("ASK31_AFTER", JSON.stringify(results));
} finally {
  await browser.close();
  await server.close();
}
