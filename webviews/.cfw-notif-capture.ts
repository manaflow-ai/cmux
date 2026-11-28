// Temporary (fork chats-flat-windowed-rows): capture agent-pane.notification-reply variants. Delete after use.
import path from "node:path";
import fs from "node:fs";
import { chromium } from "./bench/browsers";
import { galleryFrame, warmGalleryFrame } from "./test/support/galleryFrame";
const out = process.argv[2]!;
fs.mkdirSync(out, { recursive: true });
const ENTRY = "agent-pane.notification-reply";
const { createServer } = await import("vite");
const vite = await createServer({ configFile: path.resolve("vite.config.gallery-dev.ts"), server: { port: 0, host: "127.0.0.1", strictPort: false }, logLevel: "error" });
await vite.listen();
const browser = await chromium.launch({ headless: true });
await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "collapsed" } });
const port = (vite.httpServer!.address() as { port: number }).port;
for (const rep of [1, 2])
  for (const variant of ["collapsed", "open", "no-reply", "command-reply"]) {
    const page = await browser.newPage({ viewport: { width: 1600, height: 1000 }, deviceScaleFactor: 1 });
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant, width: 1500, theme: "Catppuccin Mocha", reducedMotion: "true" })}`);
    let ready = "ready";
    try { await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, { timeout: 60_000 }); } catch { ready = "NOT-READY"; }
    await page.waitForTimeout(1500);
    await page.screenshot({ path: `${out}/${variant}-r${rep}.png` });
    const rows = await page.evaluate(() => document.body.innerText.replace(/\s+/g, " ").slice(0, 600));
    fs.writeFileSync(`${out}/${variant}-r${rep}.txt`, `${ready}\n${rows}\n`);
    console.log(variant, rep, ready);
    await page.close();
  }
await browser.close();
await vite.close();
process.exit(0);
