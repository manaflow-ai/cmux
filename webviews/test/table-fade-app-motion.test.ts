// A wide table's edge fades (the Markdown viewer's and a chat reply's) and a chat table's streamed
// rows move as the app's own Reduce Motion says, not only as the system setting says. The host
// marks every page `data-cmux-motion` (WebTheme.motionValue): `reduced` under the app's Reduce Motion
// (the system setting, calm mode or the debug override), `off` with motion off, else `full`. A page
// with no host (no mark) keeps the system setting. Before, the CSS read only
// `prefers-reduced-motion`, so a capture host with Reduce Motion on recorded every fade in one frame
// even after the app turned its own Reduce Motion off (a1058, the markdown-table-motion scene).
//
// Real engines, the shipped stylesheets: each case reads the computed `transition-property` and
// `animation-name` with the system setting emulated.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("table-fade-app-motion.test.ts", async () => {
  setDefaultTimeout(120_000);
  const source = path.resolve(import.meta.dir, "../src");
  const css = ["pages/markdown/styles.css", "agent-session/acpmux/conversation/conversation.css"]
    .map((file) => fs.readFileSync(path.join(source, file), "utf8"))
    .join("\n")
    // A page's bundler resolves these; the fixture inlines the sheets itself.
    .replace(/^@import .*$/gm, "");

  const body = `
<div class="md-prose"><div class="tableWrapper" data-cmux-sideways data-more-right id="viewer"><table><tr><td>a</td></tr></table></div></div>
<div class="cv-table-block cv-enter"><div class="cv-table-wrap" data-cmux-sideways data-more-right id="chat"><table><tbody><tr id="row"><td>a</td></tr></tbody></table></div></div>`;

  type Read = { viewer: string; chat: string; row: string };
  const engines: [string, BrowserType][] = [
    ["chromium", chromium],
    ["webkit", webkit],
  ];
  const browsers = new Map<string, Browser>();
  beforeAll(async () => {
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
  });

  async function read(engine: string, system: "reduce" | "no-preference", motion?: string): Promise<Read> {
    const page = await browsers.get(engine)!.newPage({ reducedMotion: system });
    try {
      const mark = motion === undefined ? "" : ` data-cmux-motion="${motion}"`;
      await page.setContent(
        `<!doctype html><html${mark}><head><style>${css}</style></head><body>${body}</body></html>`,
      );
      return await page.evaluate(() => {
        const style = (id: string) => getComputedStyle(document.getElementById(id)!);
        return {
          viewer: style("viewer").transitionProperty,
          chat: style("chat").transitionProperty,
          row: style("row").animationName,
        };
      });
    } finally {
      await page.close();
    }
  }

  const moves = (got: Read) => {
    expect(got.viewer).toContain("--md-table-fade-left");
    expect(got.viewer).toContain("--md-table-fade-right");
    expect(got.chat).toContain("--cv-table-fade-left");
    expect(got.chat).toContain("--cv-table-fade-right");
    expect(got.row).toBe("cv-enter-fade");
  };
  const still = (got: Read) => {
    expect(got.viewer).not.toContain("--md-table-fade");
    expect(got.chat).not.toContain("--cv-table-fade");
    expect(got.row).toBe("none");
  };

  for (const [engine] of engines) {
    describe(engine, () => {
      test("the app's motion on wins over the system's Reduce Motion", async () => {
        moves(await read(engine, "reduce", "full"));
      });
      test("the app's Reduce Motion stills the fades while the system has none", async () => {
        still(await read(engine, "no-preference", "reduced"));
      });
      test("the app's motion off stills them", async () => {
        still(await read(engine, "no-preference", "off"));
      });
      test("a page with no host follows the system setting", async () => {
        moves(await read(engine, "no-preference"));
        still(await read(engine, "reduce"));
      });
    });
  }
});
