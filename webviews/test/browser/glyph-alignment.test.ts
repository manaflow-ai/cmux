// cmux-web-test-timeout: 300
// l10n-allow-file: geometry diagnostics use gallery fixture text.
import { expect, test } from "bun:test";
import { chromium } from "playwright";
import { createServer } from "vite";
import path from "node:path";
import { galleryFrame, warmGalleryFrame } from "../support/galleryFrame";
import { requireBrowserLane } from "../support/requireBrowserLane";

type Check = {
  family: string;
  row: string;
  glyph: string;
  text: string;
  centerDelta: number;
  left: number;
  size: number;
};

await requireBrowserLane("glyph-alignment.test.ts", async () => {
  const CASES = [
    {
      id: "agent-pane.workflow-side-tab",
      variant: undefined,
      selectors: [
        [
          ".acpmux-workflow-side-tab__phase",
          ".acpmux-workflow-side-tab__phase-marker svg[data-icon], .acpmux-workflow-side-tab__phase-marker .cv-spinner",
          ".acpmux-workflow-side-tab__phase-head strong",
        ],
        [
          ".acpmux-workflow-side-tab__state",
          ".acpmux-workflow-side-tab__state svg[data-icon], .acpmux-workflow-side-tab__state .cv-spinner",
          null,
        ],
      ] as const,
    },
    {
      id: "agent-pane.workflow-card",
      variant: undefined,
      selectors: [
        [".acpmux-workflow-card__head", ".acpmux-workflow-card__head svg[data-icon]", ".acpmux-workflow-card__name"],
      ] as const,
    },
    {
      id: "agent-pane.chat-inspector",
      variant: "workflow-running",
      selectors: [
        [
          ".acpmux-workflow-agent",
          ".acpmux-workflow-agent__icon svg[data-icon], .acpmux-workflow-agent__icon .cv-spinner",
          ".acpmux-workflow-agent__text",
        ],
      ] as const,
    },
    {
      id: "agent-pane.chat-inspector",
      variant: "subagents-open",
      selectors: [
        [
          ".acpmux-agent-line",
          ".acpmux-agent-line__button .acpmux-lineage__icon svg[data-icon], .acpmux-agent-line__button .acpmux-lineage__icon .cv-spinner",
          ".acpmux-summary-agent__name",
        ],
      ] as const,
    },
    {
      id: "agent-pane.subagent-tray",
      // One line, so no header and nothing folded: the frame runs no play to open a headed tray.
      variant: "one-running",
      selectors: [
        [
          ".acpmux-agent-line",
          ".acpmux-agent-line__button .acpmux-lineage__icon svg[data-icon], .acpmux-agent-line__button .acpmux-lineage__icon .cv-spinner",
          ".acpmux-summary-agent__name",
        ],
      ] as const,
    },
  ];
  test("glyphs use shared row geometry in light and dark", async () => {
    const root = path.resolve(import.meta.dir, "../..");
    const vite = await createServer({
      root,
      configFile: path.join(root, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1" },
      logLevel: "error",
    });
    await vite.listen();
    const browser = await chromium.launch();
    try {
      const port = (vite.httpServer!.address() as { port: number }).port;
      await warmGalleryFrame(
        vite,
        CASES.map(({ id }) => id),
        { browser, timeoutMs: 120_000 },
      );
      const failures: string[] = [];
      const observed: Check[] = [];
      for (const colorScheme of ["light", "dark"] as const)
        for (const entry of CASES) {
          const page = await browser.newPage({
            viewport: { width: 1000, height: 900 },
            colorScheme,
          });
          try {
            await page.goto(
              `http://127.0.0.1:${port}${galleryFrame(entry.id, {
                colorScheme,
                reducedMotion: "true",
                variant: entry.variant,
              })}`,
            );
            await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
            const checks = (await page.evaluate(
              ({ selectors, family }) =>
                selectors.flatMap(([rowSelector, glyphSelector, textSelector]) =>
                  [...document.querySelectorAll<HTMLElement>(rowSelector)].flatMap((row) => {
                    const glyph = row.querySelector<SVGElement>(glyphSelector);
                    const text = textSelector ? row.querySelector<HTMLElement>(textSelector) : row;
                    if (!glyph || !text) return [];
                    const gr = glyph.getBoundingClientRect(),
                      tr = text.getBoundingClientRect();
                    return [
                      {
                        family,
                        row: rowSelector,
                        glyph: glyph.getAttribute("data-icon") ?? glyph.className.baseVal ?? "svg",
                        text: text.textContent?.trim() ?? "",
                        centerDelta: Math.abs(gr.top + gr.height / 2 - (tr.top + tr.height / 2)),
                        glyphTop: gr.top,
                        textTop: tr.top,
                        left: gr.left,
                        size: gr.height,
                      },
                    ];
                  }),
                ),
              {
                selectors: entry.selectors as readonly (readonly [string, string, string | null])[],
                family: `${entry.id}#${entry.variant ?? "default"}`,
              },
            )) as Check[];
            if (checks.length === 0) failures.push(`${colorScheme} ${entry.id} produced no glyph observations`);
            const captureDir = process.env.GLYPH_CAPTURE_DIR;
            if (captureDir) {
              const { mkdir } = await import("node:fs/promises");
              await mkdir(captureDir, { recursive: true });
              await page.screenshot({
                path: path.join(captureDir, `${colorScheme}-${entry.id.replaceAll("/", "_")}.png`),
                fullPage: true,
              });
            }
            for (const check of checks) {
              observed.push(check);
              if (check.centerDelta > 0.5)
                failures.push(`${colorScheme} ${entry.id} ${check.row} center delta ${check.centerDelta.toFixed(2)}px`);
              if (check.size !== 14 && !check.glyph.includes("spinner"))
                failures.push(
                  `${colorScheme} ${entry.id} ${check.row} ${check.glyph} is ${check.size}px, expected 14px`,
                );
            }
          } finally {
            await page.close();
          }
        }
      for (const group of new Set(observed.map((check) => `${check.family}:${check.row}`))) {
        const lefts = observed.filter((check) => `${check.family}:${check.row}` === group).map((check) => check.left);
        const left = lefts[0];
        if (left !== undefined && lefts.some((value) => Math.abs(value - left) > 0.5))
          failures.push(`${group} glyphs do not share an icon-column left edge`);
      }
      console.log(`Glyph audit: ${observed.length} glyphs measured in light and dark.`);
      expect(failures).toEqual([]);
      expect(observed.length).toBeGreaterThan(0);
    } finally {
      await browser.close();
      await vite.close();
    }
  }, 240_000);
});
