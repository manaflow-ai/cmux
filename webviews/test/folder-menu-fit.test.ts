// The folder menus are as wide as their fullest row (design/menus.md menu-fit: at most 112 px spare
// past it), measured the way gallery health measures it (src/gallery/invariants.ts). The New Tab
// chooser drew each folder's path from a CSS `content: attr(data-path)`, text the rule (and a
// selection or a find) never sees, so a menu its paths filled read as one with 200 px to spare and
// sat in invariant-baseline.json as a known red (review of #36964). Each state below must keep no
// menu-fit violation; a "warn" state prints what it measured.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

type Violation = { rule: string; key: string; detail: string };
type FitCase = { entry: string; variant: string; level: "fail" | "warn" };

await requireBrowserLane("folder-menu-fit.test.ts", async () => {
  setDefaultTimeout(240_000);
  const chooser = (variant: string): FitCase => ({ entry: "agent-pane.project-chooser", variant, level: "fail" });
  const CASES: FitCase[] = [
    ...[
      "open-current",
      "open-path-titled",
      "open-app-icons",
      "lane-worktrees",
      "lane-worktrees-search",
      "long-no-actions",
      "machine-tags",
    ].map(chooser),
    ...["no-project", "open", "search"].map((variant) => ({
      entry: "agent-pane.empty-state",
      variant,
      level: "fail" as const,
    })),
    { entry: "agent-pane.new-tab-headline", variant: "picker-open", level: "fail" },
  ];
  const THEMES = ["Apple System Colors Light", "Catppuccin Mocha"];

  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("folder menu fit", () => test("browser", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    const warmed = new Set<string>();
    for (const item of CASES) {
      if (warmed.has(item.entry)) continue;
      warmed.add(item.entry);
      await warmGalleryFrame(vite, item.entry, { browser, params: { variant: item.variant } });
    }
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const item of CASES)
    for (const theme of THEMES)
      test(`${item.entry}#${item.variant} (${theme}): the folder menu is as wide as its fullest row`, async () => {
        const page = await browser.newPage({ viewport: { width: 760, height: 640 } });
        try {
          const port = (vite!.httpServer!.address() as { port: number }).port;
          await page.goto(`http://127.0.0.1:${port}${galleryFrame(item.entry, { variant: item.variant, theme })}`);
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
            timeout: 120_000,
          });
          await page.evaluate(() => document.fonts.ready);
          const violations = await page.evaluate(
            () => (window as unknown as { cmuxGalleryInvariants(): Violation[] }).cmuxGalleryInvariants() ?? [],
          );
          const unfit = violations.filter((violation) => violation.rule === "menu-fit");
          const menus = await page.evaluate(() =>
            [...document.querySelectorAll<HTMLElement>(".acpmux-project-menu")].map(
              (menu) => `${Math.round(menu.getBoundingClientRect().width)} px`,
            ),
          );
          console.log(
            `${item.entry}#${item.variant} (${theme}): menus ${menus.join(", ") || "none"}; ${unfit.map((v) => v.detail).join("; ") || "fits"}`,
          );
          if (item.level === "warn") return;
          expect(unfit.map((violation) => violation.detail)).toEqual([]);
        } finally {
          await page.close();
        }
      });
});
