// Selected rows in the agent pane (New Tab's rows and chats list, the omnibar and
// checked question rows) tint with the theme accent when `appearance.accent` sets one. With the
// default neutral accent the host sends the text color as `--agent-accent`, so the tint is the
// same as before. The row text stays the text color either way.
//
// The page is the pane's real stylesheets plus markup in the shape the components render. The
// engines come from `playwright install chromium webkit`; where they are not installed, the cases
// are skipped and say so.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("selected-row-accent.test.ts", async () => {
  setDefaultTimeout(120_000);
  const source = path.resolve(import.meta.dir, "../src/agent-session");
  const css = ["shared/styles.css", "acpmux/styles.css", "acpmux/newtab/screen.css", "acpmux/newtab/history.css"]
    .map((file) => fs.readFileSync(path.join(source, file), "utf8"))
    .join("\n");

  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`selected-row-accent: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`);
    }
  }

  // Rose Pine: text, base and its iris accent.
  const TEXT = "rgb(224, 222, 244)";
  const IRIS = "rgb(196, 167, 231)";
  const ROWS: [string, string][] = [
    ["New Tab row", `<div class="nt-row is-selected">Fix the build</div>`],
    ["New Tab chats row", `<div class="nt-all-row" data-selected>Fix the build</div>`],
    ["omnibar row", `<div class="acpmux-omni-row is-selected">Fix the build</div>`],
    [
      "checked question mark",
      `<div class="acpmux-question-row" aria-checked="true"><span class="acpmux-question-mark" data-multi data-chosen></span></div>`,
    ],
  ];
  const page = (accent: string) => `<!doctype html><html><head><style>
${css}
:root{--agent-text:${TEXT};--agent-accent:${accent};--agent-accent-text:rgb(25,23,36);--agent-page-bg:rgb(25,23,36);--agent-muted:rgb(144,140,170)}
</style></head><body><div class="acpmux-shell">${ROWS.map(([, html]) => html).join("")}</div></body></html>`;

  for (const [name, engine] of engines) {
    describe(`selected rows in ${name}`, () => {
      let browser: Browser;
      beforeAll(async () => {
        browser = await engine.launch({ headless: true });
      });
      afterAll(async () => browser?.close());

      const styles = async (accent: string) => {
        const tab = await browser.newPage();
        await tab.setContent(page(accent));
        const out = await tab.$$eval(".acpmux-shell > :not(.acpmux-question-row), .acpmux-question-mark", (nodes) =>
          nodes.map((node) => {
            const style = getComputedStyle(node);
            return { background: style.backgroundColor, color: style.color };
          }),
        );
        await tab.close();
        return out;
      };

      test("before a theme arrives, a selected row is not tinted with the placeholder blue", async () => {
        const tab = await browser.newPage();
        await tab.setContent(
          `<!doctype html><html><head><style>${css}</style></head><body><div class="acpmux-shell">${ROWS[0][1]}</div></body></html>`,
        );
        const [accent, text] = await tab.$eval(":root", (root) => {
          const style = getComputedStyle(root);
          return [style.getPropertyValue("--agent-accent").trim(), style.getPropertyValue("--agent-text").trim()];
        });
        expect(accent).toBe(text);
        await tab.close();
      });

      test("a theme accent tints the selection; the row text stays the text color", async () => {
        const neutral = await styles(TEXT);
        const accented = await styles(IRIS);
        ROWS.forEach(([label], index) => {
          expect(neutral[index].background, label).not.toBe("rgba(0, 0, 0, 0)");
          expect(accented[index].background, label).not.toBe(neutral[index].background);
          expect(accented[index].color, label).toBe(neutral[index].color);
        });
      });
    });
  }
});
