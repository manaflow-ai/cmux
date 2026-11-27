// l10n-allow-file: public-safe gallery evidence; synthetic contact fixtures only.
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { createServer } from "vite";

const outputDirectory = process.env.FAST_CHECKS_OUT ?? process.argv[2];
if (!outputDirectory) throw new Error("Provide an artifact directory");
const output = path.resolve(outputDirectory);
await mkdir(output, { recursive: true });
const root = path.resolve(import.meta.dir, "..");
const entrySource = "src/agent-session/acpmux/session-info/IMessageConnector.gallery.tsx";
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
  for (const scheme of ["light", "dark"] as const) {
    const page = await browser.newPage({
      viewport: { width: 420, height: 640 },
      deviceScaleFactor: 2,
      colorScheme: scheme,
    });
    const pageErrors: string[] = [];
    page.on("pageerror", (error) => {
      pageErrors.push(error.stack ?? error.message);
      if (pageErrors.length > 20) pageErrors.shift();
    });
    let activeVariant = "not-connected";
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
        activeVariant = variant;
        const query = new URLSearchParams({
          entry: "agent-pane.imessage-connector",
          entryPath: entrySource,
          variant,
          colorScheme: scheme,
          source: entrySource,
          width: "normal",
          frame: "component",
        });
        const base = new URL(server.config.base, `http://127.0.0.1:${address.port}`);
        const url = new URL(`frame.html?${query}`, base);
        pageErrors.length = 0;
        await page.goto(url.href, {
          waitUntil: "domcontentloaded",
        });
        await page.waitForFunction(() => !!document.documentElement.dataset.galleryReady, undefined, {
          timeout: 120_000,
        });
        const ready = await page.locator("html").getAttribute("data-gallery-ready");
        if (ready !== "1") throw new Error(`Gallery reported ${ready}`);
        await page.locator(".acpmux-imessage").waitFor();
        await page.evaluate(() => document.fonts.ready);
        const file = path.join(output, `${variant}-${scheme}.png`);
        await page.locator(".acpmux-session-info").screenshot({ path: file });
        console.log(`${scheme} ${variant}: ${await page.locator(".acpmux-imessage").innerText()} → ${file}`);
      }
    } catch (error) {
      const prefix = path.join(output, `${activeVariant}-${scheme}-failure`);
      const body = await page.locator("body").innerText({ timeout: 5_000 }).catch(String);
      const diagnostics = {
        variant: activeVariant,
        scheme,
        url: page.url(),
        error: error instanceof Error ? (error.stack ?? error.message) : String(error),
        pageErrors,
        body: body.slice(0, 16_000),
      };
      const artifacts = await Promise.allSettled([
        writeFile(`${prefix}.json`, JSON.stringify(diagnostics, null, 2)),
        page.screenshot({ path: `${prefix}.png`, timeout: 5_000 }),
      ]);
      console.error(`Gallery capture failed; diagnostics: ${prefix}.json; screenshot: ${prefix}.png`);
      for (const result of artifacts) if (result.status === "rejected") console.error(String(result.reason));
      throw error;
    } finally {
      await page.close();
    }
  }
} finally {
  await browser?.close();
  await server.close();
}
