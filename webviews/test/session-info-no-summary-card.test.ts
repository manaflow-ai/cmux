// With Session Info on (the host's default, AgentPaneTunables.sessionInfo), the old summary card is gone:
// no summary button, no card, no subagent rows and no "Open new subagents in panes" checkbox, and
// Session Info opens on Environment. Leo, 2026-10-31, on the summary card at the top of the pane:
// "I HATE THAT TOP BIT". #26390 switched `agent.inspector` off, so the header offered the summary
// card instead (summary/SummaryCard.tsx, summary/SubagentStatusList.tsx); this PR turns it back on.
// The off case is the control: it proves the selectors find the card when it is there.
// CMUX_BROWSER_TESTS=1 bun test test/session-info-no-summary-card.test.ts
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdirSync } from "node:fs";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { agentPaneTheme } from "../src/gallery/theme/web";
import { deriveTokens, GHOSTTY_DEFAULT, rgbHex } from "../src/gallery/theme/tokens";
import { papercutPane } from "./support/papercutChat";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("session-info-no-summary-card.test.ts", async () => {
  setDefaultTimeout(180_000);
  /// Everything the summary card draws at the top of the pane.
  const SUMMARY = ".acpmux-summary-button, .acpmux-summary-card, .acpmux-summary-agents, .acpmux-summary-autoopen";
  let browser: Browser;
  let pane: Awaited<ReturnType<typeof papercutPane>>;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
    pane = await papercutPane(() => browser, { turns: 4, running: false });
  });
  afterAll(async () => {
    await browser?.close();
    await pane?.close();
  });

  const open = async (sessionInfo: boolean, dark = false, scale = 1) => {
    const page = await pane.open({ width: 900, height: 640, scale, colorScheme: dark ? "dark" : "light" });
    // The pane's theme is the host's (applyTheme), not the browser's color scheme.
    const theme = agentPaneTheme(
      deriveTokens({
        ...GHOSTTY_DEFAULT,
        background: rgbHex(dark ? 0x1e1e1e : 0xffffff),
        foreground: rgbHex(dark ? 0xe5e5e5 : 0x1c1c1c),
      }),
      true,
    );
    await page.evaluate((theme) => window.cmuxAcpmuxBridge!.applyTheme(theme), theme);
    await page.evaluate(
      (sessionInfo) => window.cmuxAcpmuxBridge!.applyHeaderState!({ inspector: sessionInfo, version: 2 }),
      sessionInfo,
    );
    return page;
  };
  const visible = (page: Page, selector: string) =>
    page.evaluate(
      (selector) =>
        [...document.querySelectorAll<HTMLElement>(selector)].filter((node) => {
          const box = node.getBoundingClientRect();
          return box.width > 0 && box.height > 0 && getComputedStyle(node).visibility !== "hidden";
        }).length,
      selector,
    );

  test("off (the control): the header offers the summary card, and it opens", async () => {
    const page = await open(false);
    try {
      const button = page.locator("button.acpmux-summary-button");
      await button.waitFor({ timeout: 10_000 });
      if ((await button.getAttribute("aria-pressed")) !== "true") await button.click();
      await page.locator(".acpmux-summary-card").first().waitFor({ timeout: 10_000 });
      expect(await visible(page, SUMMARY)).toBeGreaterThan(0);
      expect(await page.locator("button.acpmux-session-info-toggle").count()).toBe(0);
    } finally {
      await page.close();
    }
  });

  test("on: no summary card or subagent rows anywhere, and Session Info opens on Environment", async () => {
    const page = await open(true);
    try {
      const toggle = page.locator("button.acpmux-session-info-toggle");
      await toggle.waitFor({ timeout: 10_000 });
      expect(await visible(page, SUMMARY)).toBe(0);
      if ((await toggle.getAttribute("aria-pressed")) !== "true") await toggle.click();
      const panel = page.locator("aside.acpmux-session-info");
      await panel.locator("[data-section]").first().waitFor({ timeout: 10_000 });
      expect(await panel.locator("[data-section]").first().getAttribute("data-section")).toBe("environment");
      // Nothing of the card's sits above the first section, in the panel or over it.
      const above = await page.evaluate((selector) => {
        const first = document.querySelector<HTMLElement>("aside.acpmux-session-info [data-section]")!;
        const top = first.getBoundingClientRect().top;
        return [...document.querySelectorAll<HTMLElement>(selector)].filter((node) => {
          const box = node.getBoundingClientRect();
          return box.width > 0 && box.height > 0 && box.top < top;
        }).length;
      }, SUMMARY);
      expect(above).toBe(0);
      expect(await visible(page, SUMMARY)).toBe(0);
    } finally {
      await page.close();
    }
  });

  // Before (off: the summary card) and after (on: Session Info) of the pane's top, 2x, light and dark,
  // into the fast checks artifact.
  const out = process.env.FAST_CHECKS_OUT;
  if (out)
    test("stills: the top of the pane, summary card (off) and Session Info (on)", async () => {
      mkdirSync(path.join(out, "stills"), { recursive: true });
      for (const dark of [false, true])
        for (const sessionInfo of [false, true]) {
          const page = await open(sessionInfo, dark, 2);
          try {
            const control = page.locator(
              sessionInfo ? "button.acpmux-session-info-toggle" : "button.acpmux-summary-button",
            );
            await control.waitFor({ timeout: 10_000 });
            if ((await control.getAttribute("aria-pressed")) !== "true") await control.click();
            await page
              .locator(sessionInfo ? "aside.acpmux-session-info [data-section]" : ".acpmux-summary-card")
              .first()
              .waitFor({ timeout: 10_000 });
            // Its opening animation done and the frame painted (support/paintedFrames.ts).
            await page.evaluate(async () => {
              await Promise.all(document.getAnimations().map((one) => one.finished.catch(() => undefined)));
              await window.cmuxPaintFrame();
            });
            const name = `${sessionInfo ? "after-session-info" : "before-summary-card"}-${dark ? "dark" : "light"}.png`;
            // The pane's top right: the header's tools and the panel under them, with some transcript.
            await page.screenshot({
              path: path.join(out, "stills", name),
              clip: { x: 380, y: 0, width: 520, height: 240 },
            });
          } finally {
            await page.close();
          }
        }
    });
});
