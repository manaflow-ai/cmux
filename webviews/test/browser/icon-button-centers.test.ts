// cmux-web-test-timeout: 300
// Every icon button family uses the same visible-glyph center contract.
import { expect, test } from "bun:test";
import { chromium } from "playwright";
import { createServer } from "vite";
import path from "node:path";
import { galleryFrame, warmGalleryFrame } from "../support/galleryFrame";
import { requireBrowserLane } from "../support/requireBrowserLane";
import { auditIconCentering, type IconCenterCase } from "../support/iconButtonCentering";

await requireBrowserLane("icon-button-centers.test.ts", async () => {
  const cases: readonly { id: string; variant?: string; checks: readonly IconCenterCase[] }[] = [
    {
      id: "agent-pane.code-toolbar-buttons",
      variant: "code",
      checks: [
        {
          family: "code-block toolbar",
          control: ".cv-codeblock__actions > button",
          glyph: "svg[data-icon]",
          row: ".cv-codeblock__actions",
          reference: ".cv-codeblock__header",
          referenceRoot: ".cv-codeblock",
        },
      ],
    },
    {
      id: "agent-pane.composer-hat-head-align",
      variant: "mixed",
      checks: [
        {
          family: "composer hat",
          control: ".acpmux-running-tray__head",
          glyph: "svg[data-icon]",
          row: ".acpmux-running-tray__head",
          axis: "y",
        },
        {
          family: "composer hat kinds",
          control: ".acpmux-running-tray__kind",
          glyph: ":scope > svg, :scope > .acpmux-running-tray__stack-mark",
          row: ".acpmux-running-tray__head",
          axis: "y",
        },
        {
          family: "composer hat panel",
          control: ".acpmux-running-tray__open",
          glyph: "svg[data-icon]",
          row: ".acpmux-running-tray__head",
          axis: "y",
        },
        {
          family: "composer hat chevron",
          control: ".acpmux-running-tray__chevron",
          glyph: "svg[data-icon]",
          row: ".acpmux-running-tray__head",
          axis: "y",
        },
      ],
    },
    {
      id: "agent-pane.header-tools",
      variant: "two-panes",
      checks: [
        {
          family: "chat header",
          control: ".acpmux-header-tools button",
          glyph: "[data-icon]",
          row: ".acpmux-header-tools",
        },
      ],
    },
    {
      id: "pages.sidebar-chats",
      variant: "few-rows",
      checks: [
        { family: "sidebar rows", control: ".sc-row .sc-mark", glyph: "svg[data-icon]", row: ".sc-row", axis: "y" },
        {
          family: "sidebar fold row",
          control: ".sc-header-foldable .sc-chevron",
          glyph: "svg[data-icon]",
          row: ".sc-header-foldable",
          axis: "y",
        },
      ],
    },
    {
      id: "ui.menu",
      variant: "open",
      checks: [
        {
          family: "menus",
          control: ".ui-menu-check",
          glyph: ".ui-menu-check-glyph",
          row: '[role="menuitem"]',
          axis: "y",
        },
      ],
    },
  ];

  test("icon buttons keep glyph ink centered in every family", async () => {
    const root = path.resolve(import.meta.dir, "../..");
    const vite = await createServer({
      root,
      configFile: path.join(root, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1" },
      logLevel: "error",
    });
    await vite.listen();
    const browser = await chromium.launch();
    const port = (vite.httpServer!.address() as { port: number }).port;
    try {
      await warmGalleryFrame(
        vite,
        cases.map(({ id }) => id),
        { browser, timeoutMs: 120_000 },
      );
      const failures: string[] = [];
      let observationCount = 0;
      const captureDir = process.env.GLYPH_CAPTURE_DIR;
      if (captureDir) await (await import("node:fs/promises")).mkdir(captureDir, { recursive: true });
      for (const colorScheme of ["light", "dark"] as const) {
        for (const entry of cases) {
          const page = await browser.newPage({ viewport: { width: 1000, height: 900 }, colorScheme });
          try {
            await page.goto(
              `http://127.0.0.1:${port}${galleryFrame(entry.id, {
                colorScheme,
                reducedMotion: "true",
                variant: entry.variant,
              })}`,
            );
            await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
            if (entry.id === "ui.menu")
              await page.waitForFunction(() => Boolean(document.querySelector('[role="menu"] .ui-menu-check-glyph')));
            const result = await auditIconCentering(page, entry.checks);
            observationCount += result.observations.length;
            for (const violation of result.violations)
              failures.push(
                `${colorScheme} ${violation.family} ${violation.kind} ${violation.control} ${violation.glyph}`,
              );
            if (captureDir)
              await page.screenshot({
                path: path.join(captureDir, `${colorScheme}-${entry.id.replaceAll(/[^a-z0-9]+/gi, "_")}.png`),
                fullPage: true,
              });
          } finally {
            await page.close();
          }
        }
      }
      console.log(`Icon center audit: ${observationCount} glyphs measured in light and dark.`);
      expect(observationCount).toBeGreaterThan(0);
      expect(failures).toEqual([]);
    } finally {
      await browser.close();
      await vite.close();
    }
  }, 240_000);
});
