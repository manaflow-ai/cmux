// Capture the real transcript gallery entry with a coarse pointer.
// Usage: bun capture-transcript-hover-gallery.mjs OUT_DIR [dark|light]
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import { chromium } from "playwright";
import { preview } from "vite";

const out = path.resolve(process.argv[2] ?? "transcript-hover-gallery-captures");
const scheme = process.argv[3] === "light" ? "light" : "dark";
fs.mkdirSync(out, { recursive: true });
const root = path.resolve(import.meta.dir, "../..");
const build = spawn("bun", ["run", "gallery:build"], { cwd: root, stdio: "inherit" });
await new Promise((resolve, reject) => {
  build.once("error", reject);
  build.once("exit", (code) => (code === 0 ? resolve() : reject(new Error(`gallery build exited ${code}`))));
});
const server = await preview({
  root,
  configFile: path.join(root, "vite.config.gallery.ts"),
  preview: { host: "127.0.0.1", port: 0 },
});
const address = server.httpServer.address();
if (!address || typeof address === "string") {
  server.httpServer.close();
  throw new Error("gallery preview did not bind a TCP port");
}
const baseUrl = `http://127.0.0.1:${address.port}`;
try {
  const browser = await chromium.launch();
  try {
    const context = await browser.newContext({
      viewport: { width: 1000, height: 720 },
      deviceScaleFactor: 2,
      hasTouch: true,
      colorScheme: scheme,
    });
    const page = await context.newPage();
    const url = `${baseUrl}/frame.html?entry=agent-pane.transcript&variant=footer-actions-left&colorScheme=${scheme}&width=normal&frame=component`;
    await page.goto(url, { waitUntil: "domcontentloaded" });
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 60_000,
    });
    assert.equal(await page.evaluate(() => matchMedia("(pointer: coarse)").matches), true);
    assert.equal(await page.evaluate(() => matchMedia("(hover: hover)").matches), false);
    const cdp = await context.newCDPSession(page);
    await cdp.send("DOM.enable");
    await cdp.send("CSS.enable");
    const { root: documentRoot } = await cdp.send("DOM.getDocument");
    for (const selector of [".cv-user", ".acpmux-turnSummary"]) {
      const { nodeId } = await cdp.send("DOM.querySelector", { nodeId: documentRoot.nodeId, selector });
      assert.ok(nodeId, `missing capture target ${selector}`);
      await cdp.send("CSS.forcePseudoState", { nodeId, forcedPseudoClasses: ["hover"] });
    }
    await page.evaluate(async () => {
      await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
      for (const element of document.querySelectorAll(".cv-user__actions,.cv-turn-actions")) {
        for (const animation of element.getAnimations()) {
          animation.pause();
          animation.currentTime = 0;
        }
      }
    });
    const target = page.locator(".acpmux-pane, .acpmux-shell").first();
    const box = await target.boundingBox();
    if (!box) throw new Error("transcript gallery shell did not render");
    const file = path.join(out, `after-${scheme}-coarse.png`);
    await page.screenshot({
      path: file,
      clip: {
        x: Math.max(0, box.x - 32),
        y: Math.max(0, box.y - 32),
        width: Math.min(1000, box.x + box.width + 32) - Math.max(0, box.x - 32),
        height: Math.min(720, box.y + box.height + 32) - Math.max(0, box.y - 32),
      },
    });
    const metrics = await page.evaluate(() => {
      const group = document.querySelector(".cv-turn-action-group");
      const copy = group?.querySelector('button[aria-label="Copy"]');
      const retry = group?.querySelector('button[aria-label="Retry"]');
      return {
        shell: document.querySelector(".acpmux-pane, .acpmux-shell")?.getBoundingClientRect().toJSON(),
        copyRetryGap: copy && retry ? retry.getBoundingClientRect().left - copy.getBoundingClientRect().right : null,
        dpr: devicePixelRatio,
      };
    });
    console.log(JSON.stringify({ scheme, file, metrics, base: process.env.CMUX_CAPTURE_BASE_SHA ?? null }));
    const encoded = fs.readFileSync(file).toString("base64");
    for (let offset = 0; offset < encoded.length; offset += 2000)
      console.log(`CAPTURE_BASE64 ${path.basename(file)} ${offset} ${encoded.slice(offset, offset + 2000)}`);
    await context.close();
  } finally {
    await browser.close();
  }
} finally {
  await new Promise((resolve, reject) => server.httpServer.close((error) => (error ? reject(error) : resolve())));
}
