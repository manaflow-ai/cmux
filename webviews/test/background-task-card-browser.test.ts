// l10n-allow-file: browser fixture commands and diagnostics, not shipped UI.
// cmux-web-test-timeout: 300
//
// A background command in the Background tasks panel renders as Claude Desktop's panel renders it
// (Leo, 2026-11-07: "only showing the terminal thing, I don't think is very useful ... They have it
// as a properly rendered thing"): under "Running N" each running command is a card, open, with its
// whole command in mono, wrapped, and its output streaming ("No output yet" until it prints); the
// ended ones are under "Finished N", folded. Real Chromium on the gallery stage
// (backgroundTasks/BackgroundTaskCard.gallery.tsx), light and dark.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("background-task-card-browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  const ENTRY = "agent-pane.background-task-card";
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "running-output" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function stage(variant: string, colorScheme = "dark"): Promise<{ page: Page; errors: string[] }> {
    const page = await browser!.newPage({ viewport: { width: 640, height: 520 } });
    const errors: string[] = [];
    page.on("pageerror", (error) => errors.push(error.message));
    const base = `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}`;
    await page.goto(base + galleryFrame(ENTRY, { variant, frame: "component", colorScheme }));
    await page.waitForFunction(
      () => ["1", "error"].includes(document.documentElement.dataset.galleryReady ?? ""),
      undefined,
      { timeout: 90_000 },
    );
    await page.locator(".acpmux-bg").first().waitFor();
    return { page, errors };
  }

  const heads = (page: Page) =>
    page.$$eval(".acpmux-bg__section-head", (nodes) =>
      nodes.map((node) => ({
        text: (node.textContent ?? "").replace(/\s+/g, "").trim(),
        open: node.getAttribute("aria-expanded"),
      })),
    );

  describe("a background command renders as a card, not a terminal tab", () => {
    for (const colorScheme of ["light", "dark"])
      test(`a running command's card shows its whole command and its output (${colorScheme})`, async () => {
        const { page, errors } = await stage("running-output", colorScheme);
        try {
          await page.locator(".acpmux-bg-card__output").waitFor({ timeout: 30_000 });
          const card = await page.evaluate(() => ({
            command: document.querySelector(".acpmux-bg-card__command")?.textContent ?? "",
            output: document.querySelector(".acpmux-bg-card__output")?.textContent ?? "",
            title: document.querySelector(".acpmux-bg-card__title")?.textContent ?? "",
            open: document.querySelector(".acpmux-bg-card__toggle")?.getAttribute("aria-expanded"),
          }));
          expect(card.title).toBe("Run the panel tests");
          expect(card.open).toBe("true");
          expect(card.command).toContain("cd webviews && bun test test/background-tasks-open.test.tsx");
          expect(card.output).toContain("41 pass");
          expect(await heads(page)).toEqual([{ text: "Running1", open: "true" }]);
          expect(errors).toEqual([]);
        } finally {
          await page.close();
        }
      });

    test("a command that printed nothing says No output yet", async () => {
      const { page } = await stage("running-no-output");
      try {
        await page.locator(".acpmux-bg-card__empty").waitFor({ timeout: 30_000 });
        expect(await page.locator(".acpmux-bg-card__empty").textContent()).toBe("No output yet");
        expect(await page.locator(".acpmux-bg-card__command").textContent()).toContain("gh pr checks 37840 --watch");
      } finally {
        await page.close();
      }
    });

    test("a long multi-line command shows in full, wrapped, never cut to one line", async () => {
      const { page } = await stage("long-command");
      try {
        const command = page.locator(".acpmux-bg-card__command");
        await command.waitFor({ timeout: 30_000 });
        const seen = await command.evaluate((node) => {
          const style = getComputedStyle(node);
          const line = parseFloat(style.lineHeight);
          return {
            text: node.textContent ?? "",
            lines: node.getBoundingClientRect().height / line,
            overflow: node.scrollWidth - node.clientWidth,
            whiteSpace: style.whiteSpace,
          };
        });
        expect(seen.text).toContain("print(type(d).__name__");
        expect(seen.text).toContain("/tmp/scratch/reclaim.json");
        expect(seen.lines).toBeGreaterThan(5);
        expect(seen.overflow).toBeLessThanOrEqual(1);
        expect(seen.whiteSpace).toBe("pre-wrap");
      } finally {
        await page.close();
      }
    });

    test("Running and Finished count their commands, Finished folded until opened", async () => {
      const { page } = await stage("finished-collapsed");
      try {
        await page.locator(".acpmux-bg-card").first().waitFor({ timeout: 30_000 });
        expect(await heads(page)).toEqual([
          { text: "Running1", open: "true" },
          { text: "Finished3", open: "false" },
        ]);
        expect(await page.locator(".acpmux-bg-card").count()).toBe(1);
        await page.click('[data-section="finished"] .acpmux-bg__section-head');
        await page.waitForFunction(() => document.querySelectorAll(".acpmux-bg-card").length === 4);
        // The finished cards are folded; one opens to its command in place.
        const finished = page.locator('[data-section="finished"] .acpmux-bg-card');
        expect(await finished.locator(".acpmux-bg-card__command").count()).toBe(0);
        await finished.first().locator(".acpmux-bg-card__toggle").click();
        await finished.first().locator(".acpmux-bg-card__command").waitFor();
        expect(await finished.first().locator(".acpmux-bg-card__command").textContent()).toContain(
          "scripts/web-lint.sh",
        );
      } finally {
        await page.close();
      }
    });
  });
});
