// Apps page flow coverage: exercise the real gallery page host and its supervisor-shaped mock
// through Playwright in both engines. Keep this file isolated so a failed app flow does not leave
// a shared browser or Vite server behind for another browser lane.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { mkdir } from "node:fs/promises";
import { chromium, webkit, type Browser } from "playwright";
import strings from "../src/pages/apps/generated/strings.json";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

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
    // The canonical gallery eagerly registers every stage; on a cold worktree this transform pass
    // can exceed the helper's 100s default (the matrix uses the same 300s allowance).
    // The stage registry is filtered to this entryPath; only warm the HTML shell so the browser
    // owns the targeted entry graph instead of traversing the complete gallery registry.
    await warmViteServer(vite, "/gallery/frame.html?entryPath=src/pages/apps/apps.gallery.ts", {
      timeoutMs: 30_000,
      limit: 0,
    });
    await warmViteServer(vite, "/src/gallery/frame/main.ts", {
      timeoutMs: 120_000,
      limit: 200,
    });
    await warmViteServer(vite, "/src/pages/apps/apps.gallery.ts", {
      timeoutMs: 120_000,
      limit: 600,
    });
    browsers.chromium = await chromium.launch({ headless: true });
    browsers.webkit = await webkit.launch({ headless: true });
  });

  afterAll(async () => {
    for (const browser of Object.values(browsers)) await browser.close();
    await vite?.close();
  });

  async function open(
    engine: "chromium" | "webkit",
    variant: string,
    locale = "en",
  ): Promise<import("playwright").Page> {
    const { port } = vite!.httpServer!.address() as { port: number };
    const url =
      `http://127.0.0.1:${port}/gallery/frame.html?entry=pages.apps&entryPath=src/pages/apps/apps.gallery.ts` +
      `&variant=${variant}&locale=${locale}&reducedMotion=1`;
    let lastError: unknown;
    for (let attempt = 0; attempt < 2; attempt += 1) {
      const page = await browsers[engine]!.newPage({ viewport: { width: 1100, height: 760 } });
      try {
        await page.goto(url, { timeout: 300_000 });
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
          timeout: 30_000,
        });
        return page;
      } catch (error) {
        lastError = error;
        await page.close();
        if (attempt === 0) continue;
      }
    }
    throw lastError;
  }

  for (const engine of ["webkit", "chromium"] as const) {
    for (const locale of ["en", "de", "ja"] as const) {
      test(`${engine}: App Store action widths stay fixed in ${locale}`, async () => {
        const page = await open(engine, "list", locale);
        const labels = strings[locale] as Record<string, string>;
        try {
          for (const [name, beforeKey, afterKey] of [
            ["Caffeinate", "store.action.install", "store.action.remove"],
            ["GitHub PRs", "store.action.hide", "store.action.show"],
          ] as const) {
            const card = page.locator(".apps-card").filter({ has: page.getByRole("button", { name, exact: true }) });
            const before = card.getByRole("button", { name: labels[beforeKey], exact: true });
            await before.waitFor();
            const initial = await before.boundingBox();
            expect(initial).not.toBeNull();
            const out = process.env.CMUX_APPS_WIDTH_CAPTURE_DIR;
            if (out) {
              await mkdir(out, { recursive: true });
              await card.screenshot({ path: path.join(out, `${engine}-${locale}-${beforeKey}.png`) });
            }
            await before.click();
            const after = card.getByRole("button", { name: labels[afterKey], exact: true });
            await after.waitFor();
            const changed = await after.boundingBox();
            expect(changed).not.toBeNull();
            if (out) await card.screenshot({ path: path.join(out, `${engine}-${locale}-${afterKey}.png`) });
            expect(Math.abs(changed!.width - initial!.width)).toBeLessThan(0.1);
            expect(changed!.height).toBe(initial!.height);
            await after.click();
            await before.waitFor();
            expect((await before.boundingBox())!.width).toBe(initial!.width);
          }
        } finally {
          await page.close();
        }
      });
    }
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
          await caffeinate.getByRole("button", { name: "Remove", exact: true }).waitFor();
          expect(await caffeinate.innerText()).toContain("Installed");
          expect(await caffeinate.getByRole("button", { name: "Remove" }).isVisible()).toBe(true);
        } finally {
          await page.close();
        }
      });

      test("installed update, permission, log, enable, and hide controls reflect host results", async () => {
        const page = await open(engine, "installed");
        try {
          const github = page.locator(".apps-installed > .apps-installed-row").filter({ hasText: "GitHub PRs" });
          await github.waitFor();
          expect(await github.innerText()).toContain("1.1.0");
          await github.getByRole("button", { name: "Update" }).click();
          await github.getByRole("button", { name: "Update" }).waitFor({ state: "detached" });
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
          expect(await page.getByRole("button", { name: "Reload", exact: true }).count()).toBeGreaterThan(0);
          expect(await page.getByRole("searchbox", { name: "Search apps" }).isVisible()).toBe(true);
        } finally {
          await page.close();
        }
      });

      test("retries a catalog failure without replacing the toolbar", async () => {
        const page = await open(engine, "error");
        try {
          await page.getByRole("button", { name: "Reload", exact: true }).first().click();
          await page.locator(".apps-card").first().waitFor();
          expect(await page.locator(".apps-card").count()).toBe(4);
          expect(await page.getByRole("searchbox", { name: "Search apps" }).isVisible()).toBe(true);
          expect(await page.locator('[role="alert"]').count()).toBe(0);
        } finally {
          await page.close();
        }
      });

      test("shows a not-found detail with Back and Retry", async () => {
        const page = await open(engine, "not-found");
        try {
          const state = page.locator('[data-detail-state="not-found"]');
          await state.waitFor();
          expect(await state.getByRole("button", { name: "Reload", exact: true }).isVisible()).toBe(true);
          expect(await state.getByRole("button", { name: /Discover/ }).isVisible()).toBe(true);
          expect(await page.getByRole("searchbox", { name: "Search apps" }).isVisible()).toBe(true);
        } finally {
          await page.close();
        }
      });

      test("retries a detail error while preserving the selected app", async () => {
        const page = await open(engine, "detail-error");
        try {
          const state = page.locator('[data-detail-state="error"]');
          await state.waitFor();
          expect(await state.innerText()).toContain("temporarily unavailable");
          await state.getByRole("button", { name: "Reload", exact: true }).click();
          await page.locator(".apps-detail-name").waitFor();
          expect(await page.locator(".apps-detail-name").innerText()).toBe("CodeRouter");
          expect(await page.getByRole("searchbox", { name: "Search apps" }).isVisible()).toBe(true);
        } finally {
          await page.close();
        }
      });

      test("shows the empty catalog state without inventing cards", async () => {
        const page = await open(engine, "empty");
        try {
          expect(await page.locator(".apps-card").count()).toBe(0);
          const emptyDiscover = page.locator(".apps-state-empty, .apps-empty").filter({ hasText: "No apps match" });
          await emptyDiscover.waitFor();
          expect(await emptyDiscover.innerText()).toContain("No apps match");
          await page.getByRole("tab", { name: "Installed" }).click();
          await page.locator(".apps-empty").waitFor();
          expect(await page.locator(".apps-empty").innerText()).toContain("No apps installed");
        } finally {
          await page.close();
        }
      });
    });
  }
});
