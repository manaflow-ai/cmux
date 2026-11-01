// Every row in a picker shares one icon column and one text inset; row rhythm is even inside a
// section, and a boundary that adds space shows a separator; a subtitle that equals its title is
// not shown (leo-workspace design/grid.md 5.3). Leo, on the composer's Choose project picker:
// ":( alignemnt". A picker joins by adding its selectors to CASES; a "warn" case prints what it
// measured and passes until the PR that fixes it flips it to "fail".
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import {
  describePickerRows,
  measurePickerRows,
  pickerRowProblems,
  type PickerRowCase,
} from "./support/pickerRowGeometry";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("picker-row-geometry.test.ts", async () => {
  setDefaultTimeout(240_000);
  const project = {
    entry: "agent-pane.project-chooser",
    menu: ".acpmux-project-menu",
    row: '[role="option"]',
    icon: ".acpmux-project-lead, .acpmux-project-badge, .acpmux-icon",
    title: ".acpmux-menu-label, span:not([aria-hidden])",
    subtitle: ".acpmux-menu-description",
    section: ".ui-combobox-pinned, .ui-combobox-scroll",
    level: "fail",
  } as const;

  const CASES: PickerRowCase[] = [
    { ...project, name: "project picker", variant: "open-current" },
    { ...project, name: "project picker, a folder titled by its path", variant: "open-path-titled" },
    // The agent chat's (new chat hero's) picker, Leo: "why is this all misaligned in the agent chat
    // project selectin". Do not work in a project (checked), New project and app-icon projects.
    { ...project, name: "agent chat project picker, app icons", variant: "open-app-icons" },
    { ...project, name: "agent chat project picker, lane worktrees", variant: "lane-worktrees" },
    {
      name: "environment picker",
      entry: "agent-pane.composer-context",
      variant: "environment-picker",
      menu: ".acpmux-env-popover",
      row: '[role="option"]',
      icon: ".acpmux-env-icon, .acpmux-project-badge",
      title: ".acpmux-menu-label",
      section: ".ui-combobox-pinned, .ui-combobox-scroll",
      // This Mac and Cloud, then the other machines under a hairline (no section names).
      sectionStart: ":has(> .acpmux-env-row[data-divider])",
      level: "fail",
    },
    {
      name: "model picker",
      entry: "agent-pane.model-picker",
      variant: "quick-menu",
      menu: ".acpmux-quick-menu",
      row: ".acpmux-quick-item:not(.acpmux-quick-effort-segment)",
      icon: ".acpmux-quick-icon, .acpmux-harness-icon, svg",
      title: ".acpmux-menu-label, .acpmux-quick-label",
      level: "fail",
    },
    {
      name: "mode picker",
      entry: "agent-pane.composer-pickers",
      variant: "closed",
      open: async (page) => {
        await page.getByRole("button", { name: "Mode", exact: true }).click();
        await page.locator(".acpmux-access-item").first().waitFor();
      },
      menu: ".acpmux-access-menu",
      row: ".acpmux-access-item",
      icon: ".acpmux-access-item-icon",
      title: ".acpmux-menu-label",
      level: "fail",
    },
  ];

  const THEMES = ["Apple System Colors Light", "Catppuccin Mocha"];

  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("picker row geometry", () => test("browser", () => {}));
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
    for (const item of CASES) await warmGalleryFrame(vite, item.entry, { browser, params: { variant: item.variant } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const item of CASES)
    for (const theme of THEMES)
      test(`${item.name} (${theme}): one icon column, one text inset, even rhythm, no repeated subtitle`, async () => {
        const page = await browser.newPage({ viewport: { width: 760, height: 640 } });
        try {
          const port = (vite!.httpServer!.address() as { port: number }).port;
          await page.goto(
            `http://127.0.0.1:${port}${galleryFrame(item.entry, { variant: item.variant, width: 560, theme })}`,
          );
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
            timeout: 120_000,
          });
          await page.evaluate(() => document.fonts.ready);
          await item.open?.(page);
          await page.locator(`${item.menu} ${item.row}`).first().waitFor();
          const geometry = await measurePickerRows(page, item);
          const problems = pickerRowProblems(geometry);
          console.log(`${item.name} (${theme}):\n${describePickerRows(geometry)}`);
          if (item.level === "warn") {
            for (const problem of problems) console.log(`::warning title=picker rows (${item.name})::${problem}`);
            return;
          }
          expect(problems).toEqual([]);
        } finally {
          await page.close();
        }
      });
});
