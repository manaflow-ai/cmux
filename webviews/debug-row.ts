import path from "node:path";
import { createServer } from "vite";
import { chromium } from "playwright";
import { galleryFrame } from "/home/cmux/.wt/checkouts/cmux/lane--row-rhythm-45714/webviews/test/support/galleryFrame.ts";
const root = "/home/cmux/.wt/checkouts/cmux/lane--row-rhythm-45714/webviews";
const server = await createServer({
  root,
  configFile: path.join(root, "vite.config.ts"),
  server: { port: 0, host: "127.0.0.1" },
  logLevel: "error",
});
await server.listen();
const port = (server.httpServer!.address() as any).port;
const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 640, height: 520 } });
await page.addInitScript(() => {
  (globalThis as any).cmuxExperiments = { "background-turn-look": "line" };
});
await page.goto(
  `http://127.0.0.1:${port}${galleryFrame("agent-pane.opened-run-rhythm", { variant: "running", theme: "Apple System Colors", colorScheme: "dark", width: 640, height: 520 })}`,
);
await page.waitForSelector("article[data-row-id]");
await page.waitForTimeout(1000);
console.log(
  await page.evaluate(() => ({
    attrs: Object.fromEntries([...document.documentElement.attributes].map((a) => [a.name, a.value])),
    rows: [...document.querySelectorAll("article[data-row-id]")].map((e) => ({
      id: e.getAttribute("data-row-id"),
      cls: e.className,
      text: e.textContent?.trim().slice(0, 80),
      html: e.outerHTML.slice(0, 300),
    })),
    runs: [...document.querySelectorAll("[data-message-run]")].length,
    bg: [...document.querySelectorAll("[data-background-run]")].length,
  })),
);
await browser.close();
await server.close();
