// l10n-allow-file: public-safe gallery evidence; synthetic contact fixtures only.
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { createServer } from "vite";

const output = process.env.FAST_CHECKS_OUT ?? process.argv[2];
if (!output) throw new Error("Provide an artifact directory");
const root = path.resolve(import.meta.dir, "..");
const server = await createServer({
  root,
  configFile: path.join(root, "vite.config.gallery-dev.ts"),
  server: { host: "127.0.0.1", port: 0 },
  logLevel: "warn",
});
let browser: Browser | undefined;
try {
  browser = await chromium.launch({ channel: "chrome", headless: true });
  await server.listen();
  const address = server.httpServer!.address();
  if (!address || typeof address === "string") throw new Error("Gallery did not bind a port");
  await mkdir(output, { recursive: true });
  for (const scheme of ["light", "dark"] as const) {
    const page = await browser.newPage({
      viewport: { width: 420, height: 640 },
      deviceScaleFactor: 2,
      colorScheme: scheme,
    });
    try {
      for (const variant of [
        "not-connected",
        "full-disk-access",
        "automation",
        "connected-list",
        "connected-grouped",
        "connected-details",
        "connected-read-only",
        "database-missing",
        "unavailable",
      ]) {
        const query = new URLSearchParams({
          entry: "agent-pane.imessage-connector",
          variant,
          colorScheme: scheme,
          source: "src/agent-session/acpmux/session-info/IMessageConnector.gallery.tsx",
          frame: "component",
        });
        await page.goto(`http://127.0.0.1:${address.port}/gallery/frame.html?${query}`, {
          waitUntil: "domcontentloaded",
        });
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
          timeout: 120_000,
        });
        await page.locator(".acpmux-imessage").waitFor();
        await page.evaluate(() => document.fonts.ready);
        const file = path.join(output, `${variant}-${scheme}.png`);
        await page.locator(".acpmux-session-info").screenshot({ path: file });
        console.log(`${scheme} ${variant}: ${await page.locator(".acpmux-imessage").innerText()} → ${file}`);
      }
    } finally {
      await page.close();
    }
  }
} finally {
  await browser?.close();
  await server.close();
}
