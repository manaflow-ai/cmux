#!/usr/bin/env node
// Layout check for the React pages in a real engine (headless Chromium and WebKit from Playwright):
// at 320, 400, 800 and 1400 px (a narrow tab up to a full app screen) and in English, German and
// Japanese, nothing overflows the viewport, the History title stays on one line, and every chip
// is visible (rows wrap). Each page is checked in each of its views. Starts the webviews dev server on a free port and uses the
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

/** Page views: path, the element that proves it rendered, and the elements that must fit. */
const VIEWS = [
  {
    name: "history",
    path: "/history/?mock",
    ready: ".history-row",
    fit: ".history-header *, .history-row, .history-row *",
    title: ".history-title",
    chips: ".history-chips",
  },
  {
    name: "apps-grid",
    path: "/apps/?mock",
    ready: ".apps-card",
    fit: ".apps-toolbar *, .apps-card, .apps-card *",
    chips: ".apps-chips",
  },
  {
    name: "apps-list",
    path: "/apps/?mock#/discover?layout=list",
    ready: ".apps-row",
    fit: ".apps-row, .apps-row *",
    chips: ".apps-chips",
  },
  {
    name: "apps-split",
    path: "/apps/?mock#/discover?layout=split&app=cmux.github-prs",
    ready: ".apps-detail-name",
    fit: ".apps-split *",
  },
  {
    name: "apps-detail",
    path: "/apps/?mock#/discover?app=acme.caffeinate",
    ready: ".apps-detail-name",
    fit: ".apps-detail-body *",
  },
  {
    name: "apps-installed",
    path: "/apps/?mock#/installed",
    ready: ".apps-installed-row",
    fit: ".apps-installed-row, .apps-installed-row *",
  },
];

/** Runs in the page: every problem as text. */
function measure(view) {
  const problems = [];
  const width = window.innerWidth;
  if (document.documentElement.scrollWidth > width + 0.5)
    problems.push(`page scrolls horizontally (${document.documentElement.scrollWidth} > ${width})`);
  for (const element of document.querySelectorAll(view.fit)) {
    if (element.closest(".apps-screenshots")) continue;
    const rect = element.getBoundingClientRect();
    if (rect.width > 0 && rect.right > width + 0.5)
      problems.push(`${element.className || element.tagName} ends at ${Math.round(rect.right)} > ${width}`);
  }
  if (view.title) {
    const title = document.querySelector(view.title);
    const lineHeight = parseFloat(getComputedStyle(title).fontSize) * 1.6;
    if (title.getBoundingClientRect().height > lineHeight)
      problems.push(`title wraps (${Math.round(title.getBoundingClientRect().height)}px tall)`);
  }
  const chips = view.chips && document.querySelector(view.chips);
  if (chips && chips.scrollWidth > chips.clientWidth + 0.5) problems.push("a chip row is cut off");
  return problems;
}

let failures = 0;
try {
  for (const [engineName, engine] of [
    ["chromium", chromium],
    ["webkit", webkit],
  ]) {
    const browser = await engine.launch();
    for (const locale of LOCALES)
      for (const view of VIEWS) {
        const context = await browser.newContext({ locale, viewport: { width: 800, height: 640 } });
        const page = await context.newPage();
        await page.goto(`${base}${view.path}`);
        await page.waitForSelector(view.ready);
        for (const width of WIDTHS) {
          await page.setViewportSize({ width, height: 640 });
          const problems = await page.evaluate(measure, view);
          const label = [engineName, view.name, locale, `${String(width)}px`].join(" ");
          if (problems.length) {
            failures += 1;
            console.error(`FAIL ${label}\n  ${problems.slice(0, 8).join("\n  ")}`);
          } else {
            console.log(`ok   ${label}`);
          }
          if (out) {
            fs.mkdirSync(out, { recursive: true });
            await page.screenshot({
              path: path.join(out, [view.name, engineName, locale, String(width)].join("-") + ".png"),
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
