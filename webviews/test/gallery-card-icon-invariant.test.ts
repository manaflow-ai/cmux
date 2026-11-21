// l10n-allow-file: synthetic browser fixture labels.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { chromium } from "playwright";
import type { Violation } from "../src/gallery/invariants";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("gallery-card-icon-invariant.test.ts", async () => {
  test("card artwork may centre beside two lines while a row glyph must centre on its label", async () => {
    const browser = await chromium.launch({ headless: true });
    try {
      const page = await browser.newPage();
      await page.setContent(`
        <style>
          .acpmux-scroll { width: 600px; }
          article { margin-block: 16px; font: 14px/20px Arial; }
          .acpmux-edited-head, .line { display: flex; align-items: center; gap: 24px; }
          .acpmux-edited-icon { display: grid; place-items: center; width: 40px; height: 40px; }
          svg { flex: none; width: 16px; height: 16px; }
          .acpmux-edited-icon svg { width: 24px; height: 24px; }
          .offset { transform: translateY(5px); }
        </style>
        <div class="acpmux-scroll">
          <article data-row-id="card"><div class="acpmux-edited"><div class="acpmux-edited-head">
            <div class="acpmux-edited-icon"><svg aria-hidden="true"></svg></div>
            <div>Edited files<div>+140 -0</div></div>
          </div></div></article>
          <article data-row-id="aligned" class="line"><svg aria-hidden="true"></svg><span>Read file</span></article>
          <article data-row-id="offset" class="line"><svg class="offset" aria-hidden="true"></svg><span>Read file</span></article>
        </div>`);
      const source = readFileSync(new URL("../src/gallery/invariants.ts", import.meta.url), "utf8");
      const script = new Bun.Transpiler({ loader: "ts" }).transformSync(source);
      await page.addScriptTag({
        type: "module",
        content: `${script}\nwindow.collectFixtureInvariants = collectInvariants;`,
      });
      await page.waitForFunction(() => "collectFixtureInvariants" in window);
      const violations = await page.evaluate(() =>
        (window as unknown as { collectFixtureInvariants(): Violation[] }).collectFixtureInvariants(),
      );
      expect(violations.filter(({ rule }) => rule === "center-line").map(({ key }) => key)).toEqual([
        "center-line:row offset",
      ]);
    } finally {
      await browser.close();
    }
  });
});
