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
  const cases = [
    { name: "shared", entry: "ui.menu", variant: "open", popup: ".ui-menu" },
    { name: "select", entry: "ui.select", variant: "open", popup: ".ui-menu" },
    { name: "context", entry: "ui.context-menu", variant: "open", popup: ".ui-context-menu" },
    { name: "combobox", entry: "ui.combobox", variant: "open", popup: ".ui-combobox-popup" },
    { name: "model", entry: "agent-pane.composer-pickers", variant: "claude-model-menu", popup: ".acpmux-quick-menu" },
    { name: "access", entry: "agent-pane.composer-pickers", variant: "permission-menu", popup: ".acpmux-access-menu" },
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
  for (const theme of ["light", "dark"]) {
    for (const item of cases) {
      test(`${item.name} ${theme}: menu highlight, state and text columns`, async () => {
        const page = await browser.newPage({ viewport: { width: 760, height: 700 } });
        try {
          const port = (vite.httpServer!.address() as { port: number }).port;
          await page.goto(
            `http://127.0.0.1:${port}${galleryFrame(item.entry, { variant: item.variant, theme, width: 760 })}`,
          );
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
          const popup = page.locator(item.popup).first();
          await popup.waitFor();
          if (process.env.CMUX_MENU_CAPTURE_DIR) {
            await mkdir(process.env.CMUX_MENU_CAPTURE_DIR, { recursive: true });
            await popup.screenshot({ path: path.join(process.env.CMUX_MENU_CAPTURE_DIR, `${item.name}-${theme}.png`) });
          }
          const measurements = await popup.evaluate((menu) => {
            const edge = menu.getBoundingClientRect();
            const state = Boolean(menu.querySelector(".ui-menu-check, .acpmux-project-check"));
            const rows = [...menu.querySelectorAll<HTMLElement>(".ui-menu-item, .ui-combobox-item")].filter(
              (row) => !row.classList.contains("acpmux-quick-effort-segment"),
            );
            return rows.map((row) => {
              const box = row.getBoundingClientRect();
              const check = row.querySelector<HTMLElement>(".ui-menu-check, .acpmux-project-check");
              const checkBox = check?.getBoundingClientRect();
              const label = row.querySelector(".acpmux-menu-label, .ui-menu-label") ?? row;
              const walker = document.createTreeWalker(label, NodeFilter.SHOW_TEXT);
              let node: Node | null;
              let textX: number | null = null;
              while ((node = walker.nextNode())) {
                if (!node.textContent?.trim() || node.parentElement?.closest(".ui-menu-check, .ui-menu-shortcut"))
                  continue;
                const range = document.createRange();
                range.selectNodeContents(node);
                textX = range.getBoundingClientRect().left - edge.left;
                break;
              }
              return {
                name: row.textContent?.trim(),
                inset: box.left - edge.left,
                radius: Number.parseFloat(getComputedStyle(row).borderRadius),
                height: box.height,
                stateX: checkBox && checkBox.width > 0 ? checkBox.left + checkBox.width / 2 - edge.left : null,
                textX,
                expectedTextX: state ? 42 : 35,
              };
            });
          });
          console.log(`menu-grid ${item.name} ${theme} ${JSON.stringify(measurements)}`);
          expect(measurements.length).toBeGreaterThan(0);
          for (const row of measurements) {
            expect(Math.abs(row.inset - 5), `${row.name}: highlight`).toBeLessThanOrEqual(0.5);
            expect(row.radius, `${row.name}: radius`).toBe(5);
            expect(row.height, `${row.name}: row height`).toBeGreaterThanOrEqual(28);
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
