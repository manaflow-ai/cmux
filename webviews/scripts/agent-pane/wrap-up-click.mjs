// Click an answer on the wrap-up box in the mock pane and capture the frames after it.
//   node scripts/agent-pane/wrap-up-click.mjs [out dir]
import path from "node:path";
import fs from "node:fs/promises";
import { launchBrowser, settle, startDevServer, stubMockBridge } from "./mockLaunch.mjs";

const out = path.resolve(process.argv[2] ?? "dist/wrap-up-click");
await fs.mkdir(out, { recursive: true });
const server = await startDevServer("vite.config.acpmux-pane.mjs");
const browser = await launchBrowser();
try {
  for (const sessionId of ["mock-wrap-up", "mock-wrap-up-code-mode"]) {
    const page = await browser.newPage({ viewport: { width: 900, height: 760 }, deviceScaleFactor: 2 });
    page.on("pageerror", (error) => console.log("pageerror", error.message));
    await stubMockBridge(page, { ready: { sessionId } });
    await page.goto(`${server.url}?mock`, { waitUntil: "networkidle" });
    const button = page.locator(".acpmux-next-step__answer").first();
    await button.waitFor({ timeout: 20_000 });
    await settle(page);
    const label = (await button.innerText()).split("\n")[0].trim();
    await page.screenshot({ path: path.join(out, `${sessionId}-0-before.png`) });
    // What the frame right after the click draws, then the pane later on.
    const frame = await page.evaluate(
      (label) =>
        new Promise((resolve) => {
          const target = [...document.querySelectorAll(".acpmux-next-step__answer")].find((b) =>
            b.textContent.startsWith(label),
          );
          target.click();
          requestAnimationFrame(() =>
            resolve({
              buttons: document.querySelectorAll(".acpmux-next-step__answer").length,
              quoteLines: [...document.querySelectorAll(".acpmux-scroll *")].filter(
                (n) => n.children.length === 0 && /^>\s/.test(n.textContent ?? ""),
              ).length,
            }),
          );
        }),
      label,
    );
    await page.screenshot({ path: path.join(out, `${sessionId}-1-frame.png`) });
    await page.waitForTimeout(600);
    await page.screenshot({ path: path.join(out, `${sessionId}-2-600ms.png`) });
    await page.waitForTimeout(3000);
    await page.screenshot({ path: path.join(out, `${sessionId}-3-later.png`) });
    const later = await page.evaluate(() => ({
      buttons: document.querySelectorAll(".acpmux-next-step__answer").length,
      text: document.querySelector(".acpmux-scroll")?.innerText.slice(-1500),
    }));
    console.log(JSON.stringify({ sessionId, label, frame, later }, null, 1));
    await page.close();
  }
} finally {
  await browser.close();
  await server.close();
}
