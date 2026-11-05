// l10n-allow-file: browser fixture counts and selectors, not shipped UI.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { mkdir } from "node:fs/promises";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("summary-header-surface.test.ts", async () => {
  setDefaultTimeout(180_000);
  const { createServer } = await import("vite");
  let server: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  beforeAll(async () => {
    server = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await server.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(server, "agent-pane.summary-card", {
      browser,
      params: { variant: "shared-tab-row" },
    });
  });
  afterAll(async () => {
    await browser?.close();
    await server?.close();
  });
  for (const height of [28, 40]) {
    for (const theme of ["Apple System Colors", "Apple System Colors Light"]) {
      test(`inline Summary leaves the ${height}px native tools row clear (${theme})`, async () => {
        const page = await browser.newPage({
          viewport: { width: 720, height: 560 },
        });
        try {
          const port = (server.httpServer!.address() as { port: number }).port;
          await page.goto(
            `http://127.0.0.1:${port}${galleryFrame("agent-pane.summary-card", { variant: "shared-tab-row", theme })}`,
          );
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
          await page.locator(".acpmux-shell").evaluate((node, pixels) => {
            (node as HTMLElement).style.setProperty("--acpmux-tab-row-height", `${pixels}px`);
          }, height);
          if (process.env.CMUX_SUMMARY_CAPTURE_DIR) {
            await mkdir(process.env.CMUX_SUMMARY_CAPTURE_DIR, {
              recursive: true,
            });
            await page.screenshot({
              path: path.join(
                process.env.CMUX_SUMMARY_CAPTURE_DIR,
                `summary-${height}-${theme.endsWith("Light") ? "light" : "dark"}.png`,
              ),
            });
          }
          const actual = await page.evaluate(() => {
            const shell = document.querySelector<HTMLElement>(".acpmux-shell")!;
            const panel = document.querySelector<HTMLElement>(".acpmux-summary-card")!;
            const head = panel.querySelector<HTMLElement>(".acpmux-summary-card__head")!;
            const counts = panel.querySelector<HTMLElement>(".acpmux-summary-card__counts")!;
            const rect = panel.getBoundingClientRect();
            const header = head.getBoundingClientRect();
            const text = counts.getBoundingClientRect();
            const style = getComputedStyle(counts);
            const tab = document.querySelector(".acpmux-header[data-tab-row]")!.getBoundingClientRect();
            return {
              top: rect.top - shell.getBoundingClientRect().top,
              intersectsTabRow:
                rect.left < tab.right && rect.right > tab.left && rect.top < tab.bottom && rect.bottom > tab.top,
              toolsRight: document.querySelector(".acpmux-header-tools")!.getBoundingClientRect().right,
              shellRight: shell.getBoundingClientRect().right,
              bottom: rect.bottom - shell.getBoundingClientRect().bottom,
              text: counts.textContent,
              countsInside: text.left >= header.left && text.right <= header.right,
              overflow: style.overflowX,
              truncated: counts.scrollWidth > counts.clientWidth,
              ellipsis: style.textOverflow,
              background: style.backgroundColor,
              backdrop: style.backdropFilter,
              mask: style.maskImage,
              before: getComputedStyle(counts, "::before").content,
              after: getComputedStyle(counts, "::after").content,
            };
          });
          expect(actual.text).toContain("2 commands · 1 failed");
          expect(actual.top).toBeGreaterThanOrEqual(height);
          expect(actual.intersectsTabRow).toBe(false);
          expect(actual.bottom).toBeLessThanOrEqual(0);
          expect(actual.toolsRight).toBe(actual.shellRight);
          expect(actual.countsInside).toBe(true);
          expect(actual.truncated).toBe(true);
          expect(actual).toMatchObject({
            overflow: "hidden",
            ellipsis: "ellipsis",
            background: "rgba(0, 0, 0, 0)",
            backdrop: "none",
            mask: "none",
            before: "none",
            after: "none",
          });
        } finally {
          await page.close();
        }
      });
    }
  }
  for (const width of [640, 1000]) {
    for (const height of [28, 40]) {
      for (const theme of ["Apple System Colors", "Apple System Colors Light"]) {
        test(`Preview leaves the ${height}px native row clear at ${width}px (${theme})`, async () => {
          const page = await browser.newPage({
            viewport: { width, height: 560 },
            reducedMotion: "reduce",
          });
          try {
            const port = (server.httpServer!.address() as { port: number }).port;
            await page.goto(
              `http://127.0.0.1:${port}${galleryFrame("agent-pane.summary-card", { variant: "preview-tab-row", theme })}`,
            );
            await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
            await page.locator(".acpmux-shell").evaluate((node, pixels) => {
              const shell = node as HTMLElement;
              shell.style.setProperty("--acpmux-tab-row-height", `${pixels}px`);
              if (shell.dataset.sessionInfoChatPlacement === "push")
                shell.style.setProperty("--acpmux-session-info-top", pixels > 0 ? `${pixels}px` : "28px");
            }, height);
            await page.locator(".acpmux-artifact").waitFor();
            if (process.env.CMUX_SUMMARY_CAPTURE_DIR) {
              await mkdir(process.env.CMUX_SUMMARY_CAPTURE_DIR, {
                recursive: true,
              });
              await page.screenshot({
                path: path.join(
                  process.env.CMUX_SUMMARY_CAPTURE_DIR,
                  `preview-${height}-${width}-${theme.endsWith("Light") ? "light" : "dark"}.png`,
                ),
              });
            }
            const actual = await page.evaluate(() => {
              const shell = document.querySelector(".acpmux-shell")!.getBoundingClientRect();
              const panel = document.querySelector(".acpmux-artifact")!.getBoundingClientRect();
              const tools = document.querySelector<HTMLElement>(".acpmux-header-tools")!.getBoundingClientRect();
              return {
                top: panel.top - shell.top,
                bottom: panel.bottom - shell.bottom,
                toolsWidth: tools.width,
                toolsRight: tools.right,
                shellRight: shell.right,
              };
            });
            expect(actual.top).toBe(height);
            expect(actual.bottom).toBeLessThanOrEqual(0);
            expect(actual.toolsWidth).toBeGreaterThan(0);
            expect(actual.toolsRight).toBe(actual.shellRight);
          } finally {
            await page.close();
          }
        });
      }
    }
  }
  for (const variant of [
    "preview-tab-row",
    "preview-pushed-inspector-tab-row",
    "inspector-pushed-tab-row",
    "session-info-pushed-no-tab-row",
  ] as const) {
    for (const height of variant === "session-info-pushed-no-tab-row" ? [0] : [28, 40]) {
      for (const theme of ["Apple System Colors", "Apple System Colors Light"]) {
        test(`${variant} keeps tools at the shell edge at ${height}px (${theme})`, async () => {
          const page = await browser.newPage({
            viewport: { width: 1000, height: 560 },
            reducedMotion: "reduce",
          });
          try {
            const port = (server.httpServer!.address() as { port: number }).port;
            await page.goto(`http://127.0.0.1:${port}${galleryFrame("agent-pane.summary-card", { variant, theme })}`);
            await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
            await page.locator(".acpmux-shell").evaluate((node, pixels) => {
              const shell = node as HTMLElement;
              shell.style.setProperty("--acpmux-tab-row-height", `${pixels}px`);
              if (shell.dataset.sessionInfoChatPlacement === "push")
                shell.style.setProperty("--acpmux-session-info-top", `${pixels}px`);
            }, height);
            await page.evaluate((pixels) => {
              const inspector = document.querySelector<HTMLElement>(".acpmux-session-info[data-placement=push]");
              inspector?.style.setProperty("--acpmux-session-info-top", pixels > 0 ? `${pixels}px` : "28px");
            }, height);
            if (
              process.env.CMUX_SUMMARY_CAPTURE_DIR &&
              variant === "preview-pushed-inspector-tab-row" &&
              height === 28
            ) {
              await mkdir(process.env.CMUX_SUMMARY_CAPTURE_DIR, { recursive: true });
              await page.screenshot({
                path: path.join(
                  process.env.CMUX_SUMMARY_CAPTURE_DIR,
                  `preview-pushed-inspector-${theme.endsWith("Light") ? "light" : "dark"}.png`,
                ),
              });
            }
            const actual = await page.evaluate(() => {
              const shell = document.querySelector<HTMLElement>(".acpmux-shell")!;
              const shellRect = shell.getBoundingClientRect();
              const tools = document.querySelector<HTMLElement>(".acpmux-header-tools")!.getBoundingClientRect();
              const panels = [
                ...document.querySelectorAll<HTMLElement>(
                  ".acpmux-artifact, .acpmux-session-info[data-placement=push]",
                ),
              ].map((panel) => {
                const rect = panel.getBoundingClientRect();
                return {
                  top: rect.top - shellRect.top,
                  intersectsTools:
                    rect.left < tools.right &&
                    rect.right > tools.left &&
                    rect.top < tools.bottom &&
                    rect.bottom > tools.top,
                };
              });
              return {
                toolsWidth: tools.width,
                toolsRight: tools.right,
                shellRight: shellRect.right,
                panels,
              };
            });
            expect(actual.toolsWidth).toBeGreaterThan(0);
            if (variant === "session-info-pushed-no-tab-row") {
              // Ordinary headers keep their existing 8px trailing inset; the regression is the
              // Session Info narrowing the header, which would move this edge left by the panel width.
              expect(actual.toolsRight).toBe(actual.shellRight - 8);
              await page.locator(".acpmux-header-tools button").evaluate((button) => {
                button.addEventListener("click", () => button.setAttribute("data-test-clicked", "true"), {
                  once: true,
                });
              });
              await page.locator(".acpmux-header-tools button").click();
              expect(await page.locator(".acpmux-header-tools button").getAttribute("data-test-clicked")).toBe("true");
            } else {
              expect(actual.toolsRight).toBe(actual.shellRight);
            }
            expect(actual.panels.every((panel) => panel.top >= height && !panel.intersectsTools)).toBe(true);
          } finally {
            await page.close();
          }
        });
      }
    }
  }
  test("popover starts with Environment and keeps activity counts under Subagents", async () => {
    const page = await browser.newPage({ viewport: { width: 480, height: 720 }, reducedMotion: "reduce" });
    try {
      const port = (server.httpServer!.address() as { port: number }).port;
      await page.goto(
        `http://127.0.0.1:${port}${galleryFrame("agent-pane.summary-card", { variant: "popover-environment" })}`,
      );
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
      const panel = page.locator('.acpmux-summary-card[data-placement="popover"]');
      await panel.waitFor();
      if (process.env.CMUX_SUMMARY_CAPTURE_DIR) {
        await mkdir(process.env.CMUX_SUMMARY_CAPTURE_DIR, { recursive: true });
        await panel.screenshot({ path: path.join(process.env.CMUX_SUMMARY_CAPTURE_DIR, "summary-environment.png") });
      }
      expect(await panel.locator(".acpmux-summary-card__title").count()).toBe(0);
      expect(await panel.locator("h3").first().textContent()).toBe("Environment");
      const environment = panel.locator('[data-section="environment"]');
      expect(await environment.textContent()).toContain("Development Mac");
      expect(await environment.textContent()).toContain("atlas-web");
      expect(await environment.locator("a").allTextContents()).toEqual([
        "example/atlas-web",
        "feature/session-details",
      ]);
      expect(await environment.locator("a").last().getAttribute("href")).toBe(
        "https://github.com/example/atlas-web/tree/feature/session-details",
      );
      const subagents = await panel.locator(".acpmux-summary-agents h3").textContent();
      expect(subagents).toContain("2 running");
      expect(subagents).toContain("3 commands");
      expect(await panel.textContent()).toContain("Background tasks");
      expect(await panel.textContent()).toContain("Outputs");
    } finally {
      await page.close();
    }
  });
  test("an older record's Task-tool subagent beside a running command lists Subagents once", async () => {
    const page = await browser.newPage({ viewport: { width: 480, height: 720 }, reducedMotion: "reduce" });
    try {
      const port = (server.httpServer!.address() as { port: number }).port;
      await page.goto(
        `http://127.0.0.1:${port}${galleryFrame("agent-pane.summary-card", { variant: "popover-legacy-subagents" })}`,
      );
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
      const panel = page.locator('.acpmux-summary-card[data-placement="popover"]');
      await panel.waitFor();
      const titles = await panel.locator("h3").allTextContents();
      expect(titles.filter((title) => title.startsWith("Subagents"))).toHaveLength(1);
      expect(await panel.locator('.acpmux-summary-dot[title^="Audit the retry callers"]').count()).toBe(1);
    } finally {
      await page.close();
    }
  });
  // One Stop per running task read as a column of repeated controls: it shows for the task under
  // the pointer and stays hidden on the others.
  test("a running task's Stop shows only for the task under the pointer", async () => {
    const page = await browser.newPage({ viewport: { width: 480, height: 720 }, reducedMotion: "reduce" });
    try {
      const port = (server.httpServer!.address() as { port: number }).port;
      await page.goto(
        `http://127.0.0.1:${port}${galleryFrame("agent-pane.summary-card", { variant: "popover-environment" })}`,
      );
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
      const stops = page.locator(".acpmux-summary-task > .acpmux-session-info-stop");
      expect(await stops.count()).toBeGreaterThan(1);
      const opacities = () => stops.evaluateAll((all) => all.map((stop) => getComputedStyle(stop).opacity));
      await page.mouse.move(0, 0);
      expect(new Set(await opacities())).toEqual(new Set(["0"]));
      await page.locator(".acpmux-summary-task").first().hover();
      const shown = await opacities();
      expect(shown[0]).toBe("1");
      expect(shown.slice(1).every((opacity) => opacity === "0")).toBe(true);
    } finally {
      await page.close();
    }
  });
  // The Subagents title opens the Subagents tab in both placements: beside a wide chat (inline
  // column) and over a narrow one (popover). Neither has a title row of its own.
  for (const [placement, variant, width] of [
    ["inline", "inline-subagents", 720],
    ["popover", "popover-subagents", 480],
  ] as const) {
    for (const theme of ["Apple System Colors", "Apple System Colors Light"]) {
      test(`the ${placement} Summary's Subagents title opens the Subagents tab (${theme})`, async () => {
        const page = await browser.newPage({
          viewport: { width, height: 560 },
          deviceScaleFactor: 2,
          reducedMotion: "reduce",
        });
        const mode = theme.endsWith("Light") ? "light" : "dark";
        try {
          const port = (server.httpServer!.address() as { port: number }).port;
          await page.goto(`http://127.0.0.1:${port}${galleryFrame("agent-pane.summary-card", { variant, theme })}`);
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
          const panel = page.locator(`.acpmux-summary-card[data-placement="${placement}"]`);
          await panel.waitFor();
          const capture = async (name: string) => {
            if (!process.env.CMUX_SUMMARY_CAPTURE_DIR) return;
            await mkdir(process.env.CMUX_SUMMARY_CAPTURE_DIR, { recursive: true });
            await page.screenshot({
              path: path.join(process.env.CMUX_SUMMARY_CAPTURE_DIR, `subagents-${placement}-${name}-${mode}.png`),
            });
          };
          await capture("summary");
          // Neither placement draws a "Summary" title row; both start with Environment.
          expect(await panel.locator(".acpmux-summary-card__title").count()).toBe(0);
          expect(await panel.locator("h3").first().textContent()).toBe("Environment");
          const title = panel.locator(".acpmux-summary-agents h3 .acpmux-summary-title__button");
          expect(await title.count()).toBe(1);
          expect(await title.textContent()).toContain("1 running");
          // One line, starting at the section's left edge, however many counts it carries.
          const box = (await title.boundingBox())!;
          const section = (await panel.locator(".acpmux-summary-agents").boundingBox())!;
          expect(box.height).toBeLessThanOrEqual(24);
          expect(box.x - section.x).toBeLessThanOrEqual(12);
          await title.click();
          const tabs = panel.locator(".acpmux-summary-tabs");
          await tabs.waitFor({ timeout: 5_000 });
          expect(await tabs.getByRole("button", { name: "Subagents", exact: true }).getAttribute("aria-pressed")).toBe(
            "true",
          );
          await panel.getByRole("region", { name: "Active · 1" }).waitFor({ timeout: 5_000 });
          // One way back: the tab's own close button, not a second one in the body.
          expect(await panel.getByRole("button", { name: "Close Subagents" }).count()).toBe(1);
          expect(await panel.locator("h3").first().textContent()).toBe("Environment");
          if (placement === "popover") {
            expect(await panel.getByRole("button", { name: "Collapse summary" }).count()).toBe(1);
          }
          await capture("tab");
          await panel.getByRole("button", { name: "Close Subagents" }).click();
          await panel.getByRole("region", { name: "Subagents", exact: true }).waitFor({ timeout: 5_000 });
          expect(await tabs.count()).toBe(0);
        } finally {
          await page.close();
        }
      });
    }
  }
});
