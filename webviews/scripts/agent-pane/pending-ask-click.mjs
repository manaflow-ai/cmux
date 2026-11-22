// The pinned "Needs your input" card (PendingAsks.gallery.tsx, `pinned`) before and after a click on
// its first answer, as the frame right after the click and a second later draw it. The gallery's
// send resolves at once and no prompt row follows, as when the answer waits in the queue behind a
// running turn (Leo, 2026-11-17: "after i click the behaviour is very weird").
//   node scripts/agent-pane/pending-ask-click.mjs [out dir]
import path from "node:path";
import fs from "node:fs/promises";
import { launchBrowser, settle, startDevServer } from "./mockLaunch.mjs";

const out = path.resolve(process.argv[2] ?? "dist/pending-ask-click");
await fs.mkdir(out, { recursive: true });
const server = await startDevServer("vite.config.gallery-dev.ts");
const browser = await launchBrowser();
try {
  const page = await browser.newPage({ viewport: { width: 900, height: 620 }, deviceScaleFactor: 2 });
  page.on("pageerror", (error) => console.log("pageerror", error.message));
  const base = server.url.replace(/\/$/, "");
  await page.goto(`${base}/frame.html?entry=agent-pane.pending-ask&variant=pinned&colorScheme=dark&frame=component`, {
    waitUntil: "load",
    timeout: 180_000,
  });
  const pinned = page.locator(".acpmux-pending-ask").first();
  await pinned.locator(".acpmux-next-step__answer").first().waitFor({ timeout: 120_000 });
  await settle(page);
  await page.screenshot({ path: path.join(out, "0-before.png") });
  const frame = await page.evaluate(
    () =>
      new Promise((resolve) => {
        document.querySelector(".acpmux-pending-ask .acpmux-next-step__answer").click();
        requestAnimationFrame(() =>
          resolve({ pinnedButtons: document.querySelectorAll(".acpmux-pending-ask .acpmux-next-step__answer").length }),
        );
      }),
  );
  await page.screenshot({ path: path.join(out, "1-frame.png") });
  await page.waitForTimeout(1_000);
  await page.screenshot({ path: path.join(out, "2-later.png") });
  const later = await page.evaluate(
    () => document.querySelectorAll(".acpmux-pending-ask .acpmux-next-step__answer").length,
  );
  console.log(JSON.stringify({ frame, laterPinnedButtons: later }));
} finally {
  await browser.close();
  await server.close();
}
