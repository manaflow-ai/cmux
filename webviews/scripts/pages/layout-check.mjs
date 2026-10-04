#!/usr/bin/env node
// Layout check for the React pages in a real engine (headless Chromium and WebKit from Playwright):
// at 320, 400, 800 and 1400 px and in English, German and Japanese, nothing overflows the
// viewport, the title stays on one line, the menu buttons stay inside, and every filter chip is
// visible (the row wraps). Starts the webviews dev server on a free port and uses the
// page's mock provider.
//   node scripts/pages/layout-check.mjs [--out DIR]     # screenshots go to DIR (default: none)
import { spawn } from "node:child_process";
import fs from "node:fs";
import net from "node:net";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { chromium, webkit } from "playwright";

const webviews = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const outIndex = process.argv.indexOf("--out");
const out = outIndex > 0 ? process.argv[outIndex + 1] : undefined;
const WIDTHS = [320, 400, 800, 1400];
const LOCALES = ["en-US", "de-DE", "ja-JP"];

const port = await new Promise((resolve) => {
  const server = net.createServer().listen(0, "127.0.0.1", () => {
    const { port } = server.address();
    server.close(() => resolve(port));
  });
});
const vite = spawn("bunx", ["vp", "dev", "--port", String(port), "--strictPort"], {
  cwd: webviews,
  stdio: ["ignore", "pipe", "pipe"],
});
const base = `http://127.0.0.1:${port}`;
await new Promise((resolve, reject) => {
  const onData = (chunk) => (String(chunk).includes(`${port}`) ? resolve() : undefined);
  vite.stdout.on("data", onData);
  vite.stderr.on("data", onData);
  vite.on("exit", (code) => reject(new Error(`dev server exited ${code}`)));
});

/** Runs in the page: every problem as text. */
function measure() {
  const problems = [];
  const width = window.innerWidth;
  if (document.documentElement.scrollWidth > width + 0.5)
    problems.push(`page scrolls horizontally (${document.documentElement.scrollWidth} > ${width})`);
  const chips = document.querySelector(".history-chips");
  for (const element of document.querySelectorAll(".history-header *, .history-row, .history-row *")) {
    const rect = element.getBoundingClientRect();
    if (rect.width > 0 && rect.right > width + 0.5)
      problems.push(`${element.className || element.tagName} ends at ${Math.round(rect.right)} > ${width}`);
  }
  const title = document.querySelector(".history-title");
  const lineHeight = parseFloat(getComputedStyle(title).fontSize) * 1.6;
  if (title.getBoundingClientRect().height > lineHeight)
    problems.push(`title wraps (${Math.round(title.getBoundingClientRect().height)}px tall)`);
  if (chips && chips.scrollWidth > chips.clientWidth + 0.5) problems.push("filter row is cut off");
  return problems;
}

let failures = 0;
try {
  for (const [engineName, engine] of [
    ["chromium", chromium],
    ["webkit", webkit],
  ]) {
    const browser = await engine.launch();
    for (const locale of LOCALES) {
      const context = await browser.newContext({ locale, viewport: { width: 800, height: 640 } });
      const page = await context.newPage();
      await page.goto(`${base}/history/?mock`);
      await page.waitForSelector(".history-row");
      for (const width of WIDTHS) {
        await page.setViewportSize({ width, height: 640 });
        const problems = await page.evaluate(measure);
        const label = [engineName, locale, `${String(width)}px`].join(" ");
        if (problems.length) {
          failures += 1;
          console.error(`FAIL ${label}\n  ${problems.slice(0, 8).join("\n  ")}`);
        } else {
          console.log(`ok   ${label}`);
        }
        if (out) {
          fs.mkdirSync(out, { recursive: true });
          await page.screenshot({
            path: path.join(out, ["history", engineName, locale, String(width)].join("-") + ".png"),
          });
        }
      }
      await context.close();
    }
    await browser.close();
  }
} finally {
  vite.kill();
}
process.exit(failures ? 1 : 0);
