// Fleet-only adapter around the existing gallery runner. No product behavior changes.
// Copy beside scripts/gallery-matrix/runner.ts in a pinned cmux checkout.
import { chromium } from "playwright";
import { runLocal } from "./runner.ts";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { join, basename } from "node:path";
import { createHash } from "node:crypto";
import { gzipSync } from "node:zlib";

if (process.env.GITHUB_ACTIONS !== "true" || process.platform !== "linux")
  throw new Error("Run through cmux-ci test on Linux Actions");
const [manifest, outputDir] = process.argv.slice(2);
if (!manifest || !outputDir) throw new Error("manifest and output directory required");
// The adapter preserves the runner's input/settling/screenshot lifecycle. Capture DOM at
// the same screenshot call, without another navigation or synthetic implementation.
const browserType = {
  async launch(options: Parameters<typeof chromium.launch>[0]) {
    const browser = await chromium.launch(options);
    const newContext = browser.newContext.bind(browser);
    browser.newContext = async (options) => {
      const context = await newContext(options);
      const newPage = context.newPage.bind(context);
      context.newPage = async () => {
        const page = await newPage();
        const screenshot = page.screenshot.bind(page);
        page.screenshot = async (options) => {
          const path = String(options?.path ?? "");
          if (path.endsWith(".png")) {
            const observed = await page.evaluate(() => ({
              text: document.body.innerText,
              controls: [...document.querySelectorAll("button,input,[role=option]")].map(node => ({
                tag: node.tagName, role: node.getAttribute("role"),
                label: node.getAttribute("aria-label"), text: node.textContent,
              })),
              html: document.body.innerHTML,
            }));
            writeFileSync(path.replace(/\.png$/, ".dom.json"), JSON.stringify(observed));
          }
          return screenshot(options);
        };
        return page;
      };
      return context;
    };
    return browser;
  },
};
await runLocal({ manifest, galleryDir: "webviews/dist/gallery", outputDir,
  threshold: 0, engines: ["chromium"], shardCount: 1, shardIndex: 0 },
  { chromium: browserType } as never);
const results = JSON.parse(readFileSync(join(outputDir, "results.json"), "utf8"));
const files: Record<string, string> = {};
for (const result of results) {
  for (const shot of [result.screenshot, ...(result.steps ?? []).map((step: { screenshot: string }) => step.screenshot)]) {
  for (const name of [shot, shot.replace(/\.png$/, ".dom.json")]) {
    if (basename(name) !== name) throw new Error("unsafe artifact path");
    if (!existsSync(join(outputDir, name))) {
      (result.missing_artifacts ??= []).push(name);
      continue;
    }
    const bytes = readFileSync(join(outputDir, name));
    files[name] = bytes.toString("base64");
    (result.artifacts ??= {})[name] =
      createHash("sha256").update(bytes).digest("hex");
  }
}
}
// Fast-checks retains its log, not arbitrary files. One compressed artifact payload retains
// these public-safe synthetic captures without writing to a controller or external publisher.
const bundle = { run: process.env.GITHUB_RUN_ID, results, files };
console.log("ONBOARDING_GALLERY_BUNDLE=" + gzipSync(JSON.stringify(bundle)).toString("base64"));
