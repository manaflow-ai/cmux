// Captures agent-pane.pending-ask-wallpaper (PendingAskOverWallpaper.gallery.ts): the pinned "Needs
// your input" line over a wallpaper, at the latest message and scrolled up under it.
//   node scripts/agent-pane/pending-ask-wallpaper.mjs [out dir]
import path from "node:path";
import fs from "node:fs/promises";
import { launchBrowser, settle, startDevServer } from "./mockLaunch.mjs";

const out = path.resolve(process.argv[2] ?? "dist/pending-ask-wallpaper");
await fs.mkdir(out, { recursive: true });
const server = await startDevServer("vite.config.gallery-dev.ts");
const browser = await launchBrowser();
try {
  const base = server.url.replace(/\/$/, "");
  for (const variant of ["at-latest", "scrolled-under"]) {
    const page = await browser.newPage({ viewport: { width: 900, height: 640 }, deviceScaleFactor: 2 });
    page.on("pageerror", (error) => console.log("pageerror", error.message));
    await page.goto(
      `${base}/frame.html?entry=agent-pane.pending-ask-wallpaper&variant=${variant}&colorScheme=dark&width=normal`,
      { waitUntil: "load", timeout: 180_000 },
    );
    await page.waitForFunction(
      () => ["1", "error"].includes(document.documentElement.dataset.galleryReady ?? ""),
      null,
      {
        timeout: 120_000,
      },
    );
    await settle(page);
    await page.screenshot({ path: path.join(out, `${variant}.png`) });
    const holes = await page.evaluate(
      () => getComputedStyle(document.querySelector(".acpmux-scroll")).getPropertyValue("--acpmux-dock-holes") || "",
    );
    console.log(JSON.stringify({ variant, holes: holes.trim().slice(0, 120) }));
    await page.close();
  }
} finally {
  await browser.close();
  await server.close();
}
