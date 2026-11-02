// cmux-web-test-timeout: 240
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("checkmark-alignment.test.ts", async () => {
  setDefaultTimeout(240_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  // The Claude Code pickers keep their own settled columns, the chosen row's check in its number's
  // place at the trailing edge: the model picker and its side menus (leo-workspace
  // design/model-picker.md, #29791; quick-model-menu-layout.test.ts, model-menu-density.browser.test.ts)
  // and the mode menu (composer-claude-split.test.ts, access-grants-columns.test.ts).
  const cases = [
    { name: "plus", entry: "agent-pane.composer-plus-menu", variant: "balanced", popup: ".acpmux-palette-menu" },
    { name: "chat", entry: "agent-pane.header-tools", variant: "menu-open", popup: ".acpmux-chat-menu-popover" },
    { name: "shared", entry: "ui.menu", variant: "open", popup: ".ui-menu" },
    { name: "select", entry: "ui.select", variant: "open", popup: ".ui-menu" },
    { name: "context", entry: "ui.context-menu", variant: "open", popup: ".ui-context-menu" },
    { name: "combobox", entry: "ui.combobox", variant: "open", popup: ".ui-combobox-popup" },
    { name: "project", entry: "agent-pane.project-chooser", variant: "open-current", popup: ".acpmux-project-menu" },
  ];
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    for (const item of cases) await warmGalleryFrame(vite, item.entry, { browser, params: { variant: item.variant } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });
  // Dark and light in the document's direction, and light right-to-left: every column is measured
  // from the menu's leading edge, so a physical padding shows up as a moved column.
  const runs: [string, "ltr" | "rtl"][] = [
    ["light", "ltr"],
    ["dark", "ltr"],
    ["light", "rtl"],
  ];
  for (const [theme, dir] of runs) {
    for (const item of cases) {
      test(`${item.name} ${theme} ${dir}: menu highlight, state, heading and text columns`, async () => {
        const page = await browser.newPage({ viewport: { width: 760, height: 700 } });
        try {
          const port = (vite.httpServer!.address() as { port: number }).port;
          await page.goto(
            `http://127.0.0.1:${port}${galleryFrame(item.entry, { variant: item.variant, theme: theme === "light" ? "Apple System Colors Light" : "Apple System Colors", width: 760 })}`,
          );
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
          const popup = page.locator(item.popup).first();
          await popup.waitFor();
          // The gallery has no direction switch; the menu portals into the document and inherits its dir.
          await page.evaluate((value) => {
            document.documentElement.dir = value;
          }, dir);
          if (process.env.CMUX_MENU_CAPTURE_DIR && dir === "ltr") {
            await mkdir(process.env.CMUX_MENU_CAPTURE_DIR, { recursive: true });
            await popup.screenshot({ path: path.join(process.env.CMUX_MENU_CAPTURE_DIR, `${item.name}-${theme}.png`) });
          }
          const measurements = await popup.evaluate((menu) => {
            const edge = menu.getBoundingClientRect();
            const rtl = getComputedStyle(menu).direction === "rtl";
            // Distance from the menu's leading edge: its left, or its right in a right-to-left menu.
            const lead = (box: DOMRect) => (rtl ? edge.right - box.right : box.left - edge.left);
            const mid = (box: DOMRect) => (rtl ? edge.right - (box.left + box.width / 2) : box.left + box.width / 2 - edge.left);
            const state = Boolean(menu.querySelector(".ui-menu-check, .acpmux-project-check"));
            // An icon column only when a row carries an icon (schemas/menu-metrics iconX).
            const icon = Boolean(
              menu.querySelector(
                ":is(.ui-menu-item, .ui-combobox-item, .acpmux-palette-menu .acpmux-menu-item) > :is(.ui-menu-icon, .acpmux-icon, .acpmux-project-badge, .acpmux-project-lead, svg)",
              ),
            );
            const rows = [
              ...menu.querySelectorAll<HTMLElement>(
                ".ui-menu-item, .ui-combobox-item, .acpmux-palette-menu .acpmux-menu-item",
              ),
            ];
            const textStart = (label: Element) => {
              const walker = document.createTreeWalker(label, NodeFilter.SHOW_TEXT);
              let node: Node | null;
              while ((node = walker.nextNode())) {
                if (!node.textContent?.trim() || node.parentElement?.closest(".ui-menu-check, .ui-menu-shortcut"))
                  continue;
                const range = document.createRange();
                range.selectNodeContents(node);
                return lead(range.getBoundingClientRect());
              }
              return null;
            };
            const expectedTextX = state ? (icon ? 42 : 22) : icon ? 35 : 15;
            // A group's heading starts on its rows' text column.
            const headings = [...menu.querySelectorAll(".ui-menu-group-label, .acpmux-menu-header")]
              .filter((heading) => heading.getBoundingClientRect().width > 0)
              .map((heading) => ({
                name: `heading ${heading.textContent?.trim()}`,
                inset: null as number | null,
                radius: null as number | null,
                height: null as number | null,
                stateX: null as number | null,
                textX: textStart(heading),
                expectedTextX,
              }));
            return headings.concat(rows.map((row) => {
              const box = row.getBoundingClientRect();
              const check = row.querySelector<HTMLElement>(".ui-menu-check, .acpmux-project-check");
              const checkBox = check?.getBoundingClientRect();
              const label = row.querySelector(".acpmux-menu-label, .ui-menu-label, .acpmux-chat-menu-label") ?? row;
              return {
                name: row.textContent?.trim(),
                inset: lead(box),
                radius: Number.parseFloat(getComputedStyle(row).borderRadius),
                height: box.height,
                stateX: checkBox && checkBox.width > 0 ? mid(checkBox) : null,
                textX: textStart(label),
                expectedTextX,
              };
            }));
          });
          console.log(`menu-grid ${item.name} ${theme} ${dir} ${JSON.stringify(measurements)}`);
          expect(measurements.length).toBeGreaterThan(0);
          for (const row of measurements) {
            if (row.inset !== null) expect(Math.abs(row.inset - 5), `${row.name}: highlight`).toBeLessThanOrEqual(0.5);
            if (row.radius !== null) expect(row.radius, `${row.name}: radius`).toBe(5);
            if (row.height !== null) expect(row.height, `${row.name}: row height`).toBeGreaterThanOrEqual(28);
            if (row.stateX !== null) expect(Math.abs(row.stateX - 10), `${row.name}: state`).toBeLessThanOrEqual(0.5);
            if (row.textX !== null)
              expect(Math.abs(row.textX - row.expectedTextX), `${row.name}: text`).toBeLessThanOrEqual(0.5);
          }
        } finally {
          await page.close();
        }
      });
    }
  }
});
