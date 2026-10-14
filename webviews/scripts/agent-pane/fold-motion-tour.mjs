#!/usr/bin/env node
// Records the "Worked for" fold's transitions (cx-o90g7): a turn runs, ends and folds its steps,
// then the reader opens and closes the fold. One video per mode, so the modes can be compared.
//
//   bun scripts/agent-pane/fold-motion-tour.mjs --out DIR [--modes slide,fade,none]
//
// The mock's own turn paces its steps (350 ms each), so the running state shows before the fold.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createServer } from "vite";
import { chromium } from "playwright";
import { agentPaneTheme, ghosttyDefault } from "./theme.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const webviews = path.resolve(here, "../..");
const arg = (name, fallback) => {
  const at = process.argv.indexOf(`--${name}`);
  return at > 0 ? process.argv[at + 1] : fallback;
};
const out = path.resolve(arg("out", "fold-motion-tour"));
const modes = arg("modes", "slide,fade,none").split(",");
const server = await createServer({
  configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
  server: { port: 0, host: "127.0.0.1" },
  logLevel: "error",
});
await server.listen();
const url = server.resolvedUrls.local[0];
const browser = await chromium.launch({ headless: true });
const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
try {
  for (const mode of modes) {
    const dir = path.join(out, mode);
    fs.mkdirSync(dir, { recursive: true });
    const size = { width: 900, height: 720 };
    const context = await browser.newContext({ viewport: size, colorScheme: "dark", recordVideo: { dir, size } });
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", (error) => errors.push(error.message));
    await page.addInitScript(() => {
      window.cmuxAcpmuxActions = { ready: async () => ({ protocolVersion: 1, transport: "mock" }) };
    });
    await page.goto(`${url}#foldMotion=${mode}`, { waitUntil: "networkidle" });
    await page.waitForFunction(() => window.cmuxAcpmuxBridge && window.cmuxAcpmuxActions?.["chat.send"]);
    await page.evaluate((theme) => window.cmuxAcpmuxBridge.applyTheme(theme), agentPaneTheme(ghosttyDefault));
    await pause(600);
    // Running, then the turn ends and folds its steps.
    await page.evaluate(() => window.cmuxAcpmuxActions["chat.send"]({ text: "Make greet() take its punctuation" }));
    await page.waitForFunction(() => document.querySelector('.acpmux-scroll [data-row-id^="summary-"]'), null, {
      timeout: 60_000,
    });
    await pause(1500);
    // The reader opens the newest turn's fold, then closes it. A DOM click: Playwright's own scrolls it into view.
    const toggle = () => page.evaluate(() => [...document.querySelectorAll(".cv-worked.is-toggle")].at(-1)?.click());
    await toggle();
    await pause(1500);
    await toggle();
    await pause(1500);
    await context.close();
    const video = fs.readdirSync(dir).find((name) => name.endsWith(".webm"));
    if (video) fs.renameSync(path.join(dir, video), path.join(out, `${mode}.webm`));
    fs.rmSync(dir, { recursive: true, force: true });
    if (errors.length) throw new Error(`${mode}: the page threw: ${errors.join("; ")}`);
    console.log(`${mode}: ${path.join(out, `${mode}.webm`)}`);
  }
} finally {
  await browser.close();
  await server.close();
}
