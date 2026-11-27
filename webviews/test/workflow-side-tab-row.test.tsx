// l10n-allow-file: browser fixture labels, not shipped UI.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { renderToStaticMarkup } from "react-dom/server";
import { chromium, type Browser } from "playwright";
import { WorkflowSideTab } from "../src/agent-session/acpmux/summary/WorkflowSideTab";
import { workflowOf } from "../src/agent-session/acpmux/summary/foldWorkflows";
import { workflowFixture } from "../src/agent-session/acpmux/summary/workflowFixture";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("workflow-side-tab-row.test.tsx", () => {
  const css = readFileSync(new URL("../src/agent-session/acpmux/summary/WorkflowSideTab.css", import.meta.url), "utf8");
  const node = workflowFixture("finished").find((entry) => entry.kind === "workflow")!;
  const markup = renderToStaticMarkup(
    <WorkflowSideTab workflow={workflowOf(node, "fixture")} onClose={() => undefined} />,
  );
  let browser: Browser;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
  });

  for (const height of [28, 40]) {
    test(`the workflow side tab leaves the ${height}px shared tab row clear`, async () => {
      const page = await browser.newPage();
      try {
        await page.setContent(`<style>
          .acpmux-shell { position: relative; width: 600px; height: 500px; }
          .tab-row { position: absolute; inset: 0 0 auto; height: var(--acpmux-tab-row-height); }
          ${css}
        </style><section class="acpmux-shell" data-tab-row style="--acpmux-tab-row-height:${height}px">
          <div class="tab-row">Chat tab and trailing tools</div>${markup}
        </section>`);
        const bounds = await page.evaluate(() => {
          const row = document.querySelector(".tab-row")!.getBoundingClientRect();
          const side = document.querySelector(".acpmux-workflow-side-tab")!.getBoundingClientRect();
          const shell = document.querySelector(".acpmux-shell")!.getBoundingClientRect();
          return { rowBottom: row.bottom, sideTop: side.top, sideBottom: side.bottom, shellBottom: shell.bottom };
        });
        expect(bounds.sideTop).toBeGreaterThanOrEqual(bounds.rowBottom);
        expect(bounds.sideBottom).toBe(bounds.shellBottom);
        // In a standalone web chat there is no native shared tab row to reserve.
        await page.locator(".acpmux-shell").evaluate((shell) => shell.removeAttribute("data-tab-row"));
        expect(
          await page.locator(".acpmux-workflow-side-tab").evaluate((side) => side.getBoundingClientRect().top),
        ).toBe(await page.locator(".acpmux-shell").evaluate((shell) => shell.getBoundingClientRect().top));
      } finally {
        await page.close();
      }
    });
  }
});
