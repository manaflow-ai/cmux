// Every internal page the app ships (the agent pane, each React page, Agent Activity) loads the
// shared stylesheet: its body computes the UI font stack, Inter first with the system's after it
// (`--font-ui`, schemas/type-scale/type-scale.json), not the engine default serif (WebKit reports
// that as `-webkit-standard`).
// Agent Activity shipped with its shared desktop.css dropped from the bundle and rendered in Times
// (Leo, 2026-10-13).
//
// The pages are the built resources (CI builds the web bundles before this suite; locally run
// scripts/cmux-next/build-web-bundles.sh first). Real WebKit from Playwright, as the app hosts them.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { webkit, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("internal-pages-app-font.test.ts", async () => {
  setDefaultTimeout(120_000);
  const sources = path.resolve(import.meta.dir, "../../Packages/macOS/CmuxNext/Sources");

  /** The built internal pages: (name, index.html). */
  function builtPages(): [string, string][] {
    const pages: [string, string][] = [];
    const add = (name: string, file: string) => fs.existsSync(file) && pages.push([name, file]);
    add("agent-pane", path.join(sources, "CmuxNextAgentPane/Resources/agent-pane/index.html"));
    add("agent-activity", path.join(sources, "CmuxNextAgentActivity/Resources/agent-activity/index.html"));
    const root = path.join(sources, "CmuxNextPages/Resources/pages");
    for (const page of fs.existsSync(root) ? fs.readdirSync(root).sort() : []) {
      add(`pages/${page}`, path.join(root, page, "index.html"));
    }
    return pages;
  }

  const pages = builtPages();
  const activityBuilt = pages.some(([name]) => name === "agent-activity");
  if (!activityBuilt && process.env.CI) throw new Error("internal-pages-app-font: the web bundles are not built");
  if (!activityBuilt) {
    console.warn("internal-pages-app-font: skipping (run scripts/cmux-next/build-web-bundles.sh)");
    describe.skip("internal pages", () => test("built", () => {}));
    return;
  }
  try {
    await (await webkit.launch({ headless: true })).close();
  } catch {
    console.warn("internal-pages-app-font: skipping (run `bunx playwright install webkit`)");
    describe.skip("internal pages", () => test("webkit", () => {}));
    return;
  }

  let browser: Browser | undefined;
  beforeAll(async () => {
    browser = await webkit.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
  });

  describe("internal pages", () => {
    test.each(pages)("%s renders in the app font, not the default serif", async (_name, file) => {
      const page = await browser!.newPage({ viewport: { width: 900, height: 600 } });
      try {
        await page.goto(pathToFileURL(file).href, { waitUntil: "load" });
        const font = await page.evaluate(() => getComputedStyle(document.body).fontFamily);
        expect(font).toMatch(/^\s*"?Inter"?\s*,/);
        expect(font).toMatch(/system-ui|-apple-system/);
        expect(font).not.toMatch(/^\s*"?(-webkit-standard|Times|serif)/i);
      } finally {
        await page.close();
      }
    });
  });
});
