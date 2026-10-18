// Apps page flow coverage: exercise the real gallery page host and its supervisor-shaped mock
// through Playwright in both engines. Keep this file isolated so a failed app flow does not leave
// a shared browser or Vite server behind for another browser lane.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmDevServer } from "./support/warmDevServer";

await requireBrowserLane("apps-flow.test.ts", async () => {
  setDefaultTimeout(360_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers: Record<string, Browser> = {};

  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    const { port } = vite.httpServer!.address() as { port: number };
    // The canonical gallery eagerly registers every stage; on a cold worktree this transform pass
    // can exceed the helper's 100s default (the matrix uses the same 300s allowance).
    await warmDevServer(`http://127.0.0.1:${port}`, "/gallery/frame.html", { timeoutMs: 300_000 });
    browsers.chromium = await chromium.launch({ headless: true });
    browsers.webkit = await webkit.launch({ headless: true });
  });

  afterAll(async () => {
    for (const browser of Object.values(browsers)) await browser.close();
    await vite?.close();
  });

  async function open(engine: "chromium" | "webkit", variant: string): Promise<import("playwright").Page> {
    const page = await browsers[engine]!.newPage({ viewport: { width: 1100, height: 760 } });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/gallery/frame.html?entry=pages.apps&variant=${variant}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    return page;
  }

  for (const engine of ["chromium", "webkit"] as const) {
    describe(`${engine}: Apps discover and lifecycle`, () => {
      test("search, category, detail, keyboard reset, and install use the page host", async () => {
        const page = await open(engine, "list");
        try {
          const cards = page.locator(".apps-card");
          expect(await cards.count()).toBe(4);

          const search = page.getByRole("searchbox", { name: "Search apps" });
          await search.fill("caffeinate");
          expect(await cards.count()).toBe(1);
          expect(await cards.first().innerText()).toContain("Caffeinate");
          await search.press("Escape");
          expect(await search.inputValue()).toBe("");
          expect(await cards.count()).toBe(4);

          await page.getByRole("button", { name: "Productivity" }).click();
          expect(await cards.count()).toBe(1);
          expect(await cards.first().innerText()).toContain("Caffeinate");
          await page.getByRole("button", { name: "All", exact: true }).click();
          expect(await cards.count()).toBe(4);

          await cards.filter({ hasText: "Caffeinate" }).getByRole("button", { name: "Caffeinate" }).click();
          const detailName = page.locator(".apps-detail-name");
          await detailName.waitFor();
          expect(await detailName.innerText()).toBe("Caffeinate");
          expect(await page.locator(".apps-detail").innerText()).toContain("Permissions");
          await page.locator(".apps-back").click();
          expect(await cards.count()).toBe(4);

          const caffeinate = cards.filter({ hasText: "Caffeinate" });
          await caffeinate.getByRole("button", { name: "Install" }).click();
          await page.waitForFunction(() =>
            [...document.querySelectorAll<HTMLElement>(".apps-card")].some(
              (card) =>
                card.textContent?.includes("Caffeinate") &&
                [...card.querySelectorAll("button")].some((button) => button.textContent?.includes("Remove")),
            ),
          );
          expect(await caffeinate.innerText()).toContain("Installed");
          expect(await caffeinate.getByRole("button", { name: "Remove" }).isVisible()).toBe(true);
        } finally {
          await page.close();
        }
      });

      test("installed update, permission, log, enable, and hide controls reflect host results", async () => {
        const page = await open(engine, "installed");
        try {
          const github = page.locator(".apps-installed-row").filter({ hasText: "GitHub PRs" });
          await github.waitFor();
          expect(await github.innerText()).toContain("1.1.0");
          await github.getByRole("button", { name: "Update" }).click();
          await page.waitForFunction(() => document.body.innerText.includes("1.2.0"));
          expect(await github.innerText()).toContain("1.2.0");
          expect(await github.getByRole("button", { name: "Update" }).count()).toBe(0);

          await github.getByRole("button", { name: "Permissions" }).click();
          await github.locator(".apps-grants").waitFor();
          expect(await github.locator(".apps-grants").isVisible()).toBe(true);
          await github.getByRole("button", { name: "Logs" }).click();
          await github.locator(".apps-logs").waitFor();
          await page.waitForFunction(() =>
            document.querySelector(".apps-logs")?.textContent?.includes("cmux.github-prs started"),
          );
          expect(await github.locator(".apps-logs").innerText()).toContain("cmux.github-prs started");
          const enabled = github.getByRole("switch", { name: "Enabled", exact: true });
          await enabled.click();
          await page.waitForFunction(() =>
            [...document.querySelectorAll<HTMLElement>(".apps-installed-row")].some(
              (row) =>
                row.textContent?.includes("GitHub PRs") &&
                row.querySelector('[role="switch"][aria-label="Enabled"][aria-checked="false"]'),
            ),
          );
          expect(await enabled.getAttribute("aria-checked")).toBe("false");
          await github.getByRole("button", { name: "Hide", exact: true }).click();
          const show = github.getByRole("button", { name: "Show", exact: true });
          await show.waitFor();
          expect(await show.isVisible()).toBe(true);
        } finally {
          await page.close();
        }
      });
    });

    describe(`${engine}: Apps loading, error, and empty states`, () => {
      test("keeps the loading surface mounted while catalog data is pending", async () => {
        const page = await open(engine, "loading");
        try {
          expect(await page.locator(".apps-page").isVisible()).toBe(true);
          expect(await page.locator(".apps-search").isVisible()).toBe(true);
          expect(await page.locator(".apps-card").count()).toBe(0);
        } finally {
          await page.close();
        }
      });

      test("shows the owner error and preserves the toolbar", async () => {
        const page = await open(engine, "error");
        try {
          expect(await page.locator(".apps-error").innerText()).toContain("catalog is unavailable");
          expect(await page.getByRole("searchbox", { name: "Search apps" }).isVisible()).toBe(true);
        } finally {
          await page.close();
        }
      });

      test("shows the empty catalog state without inventing cards", async () => {
        const page = await open(engine, "empty");
        try {
          expect(await page.locator(".apps-card").count()).toBe(0);
          expect(await page.locator(".apps-state-empty").innerText()).toContain("No apps match");
          await page.getByRole("tab", { name: "Installed" }).click();
          expect(await page.locator(".apps-empty").innerText()).toContain("No apps installed");
        } finally {
          await page.close();
        }
      });
    });
  }
});
