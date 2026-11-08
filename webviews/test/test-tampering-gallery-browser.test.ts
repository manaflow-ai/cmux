// l10n-allow-file: browser fixture text and diagnostics, not shipped UI.
// cmux-web-test-timeout: 300
// The alarm's three gallery states in Chromium: evidence stays exact and readable, disclosures
// open and close without losing findings, and the card remains inside its frame in both themes.
// FAST_CHECKS_OUT optionally receives compact and expanded screenshots for review.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("test-tampering-gallery-browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  const ENTRY = "agent-pane.test-tampering";
  const WIDTH = 640;
  const HEIGHT = 600;
  const VARIANTS = ["compact", "expanded", "multiFile"] as const;
  const out = process.env.FAST_CHECKS_OUT;
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
    browser = await chromium.launch({ headless: true, timeout: 30_000 });
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "compact", locale: "en" }, timeoutMs: 100_000 });
    if (out) await mkdir(out, { recursive: true });
  });
  afterAll(async () => {
    try {
      await browser?.close();
    } finally {
      await vite?.close();
    }
  });

  describe("test tampering evidence", () => {
    for (const variant of VARIANTS)
      for (const scheme of ["light", "dark"] as const)
        test(`${variant} (${scheme})`, async () => {
          const page = await browser!.newPage({
            viewport: { width: WIDTH, height: HEIGHT },
            deviceScaleFactor: 2,
            locale: "en-US",
            colorScheme: scheme,
            reducedMotion: "reduce",
          });
          page.setDefaultTimeout(10_000);
          const errors: string[] = [];
          page.on("pageerror", (error) => errors.push(error.message));
          try {
            const base = `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}`;
            await page.goto(
              base + galleryFrame(ENTRY, { variant, colorScheme: scheme, locale: "en", width: WIDTH, height: HEIGHT }),
              { timeout: 30_000 },
            );
            await page.waitForFunction(
              () => ["1", "error"].includes(document.documentElement.dataset.galleryReady ?? ""),
              undefined,
              { timeout: 90_000 },
            );
            expect(await page.evaluate(() => document.documentElement.dataset.galleryReady)).toBe("1");
            const card = page.locator(".acpmux-tampering");
            await card.waitFor();
            expect(await card.count()).toBe(1);
            const disclosure = card.locator(".acpmux-tampering-head");
            const expanded = await disclosure.getAttribute("aria-expanded");
            expect(["true", "false"]).toContain(expanded);
            if (variant === "compact") {
              expect(expanded).toBe("false");
              expect(await card.locator(".acpmux-tampering-body").count()).toBe(0);
              if (out)
                await card.screenshot({ path: path.join(out, `test-tampering-${variant}-${scheme}-closed.png`) });
            }
            if (expanded !== "true") await disclosure.click();
            await card.locator(".acpmux-tampering-body").waitFor();
            expect(await disclosure.getAttribute("aria-expanded")).toBe("true");

            const evidence = card.locator(".acpmux-tampering-list > li");
            expect(await evidence.count()).toBe(variant === "multiFile" ? 2 : 1);
            const first = evidence.first();
            expect(await first.locator(".acpmux-tampering-evidence-title code").textContent()).toBe(
              "tests/auth.test.ts",
            );
            expect(await first.locator(".acpmux-tampering-evidence-title").textContent()).toMatch(/\b18\b/);
            expect(await first.locator("pre del").textContent()).toBe("expect(response.status).toEqual(401)");
            expect(await first.locator("pre ins").textContent()).toBe("expect(response.status).toBeTruthy()");
            const reason = await first.locator(".acpmux-tampering-message").textContent();
            expect(reason).not.toContain("testTampering.");
            expect(reason).toMatch(/assertion/i);
            expect(reason).toMatch(/exact|truth|weaken/i);
            if (variant === "multiFile") {
              const second = evidence.nth(1);
              expect(await second.locator(".acpmux-tampering-evidence-title code").textContent()).toBe(
                "crates/api/tests/auth.rs",
              );
              expect(await second.locator(".acpmux-tampering-evidence-title").textContent()).toMatch(/\b32\b/);
              const removed = await second.locator(".acpmux-tampering-message").textContent();
              expect(removed).not.toContain("testTampering.");
              expect(removed).toMatch(/assertion/i);
              expect(removed).toMatch(/remov/i);
            }

            const layout = await card.evaluate((element) => {
              const viewport = document.documentElement.clientWidth;
              const boxes = [element, ...element.querySelectorAll("button, pre, .acpmux-tampering-evidence-title")];
              return {
                pageWidth: document.documentElement.scrollWidth,
                viewport,
                overflow: boxes
                  .filter((box) => {
                    const bounds = box.getBoundingClientRect();
                    return bounds.left < -1 || bounds.right > viewport + 1 || box.scrollWidth > box.clientWidth + 1;
                  })
                  .map((box) => box.className || box.tagName),
              };
            });
            expect(layout.pageWidth).toBeLessThanOrEqual(layout.viewport + 1);
            expect(layout.overflow).toEqual([]);
            if (out) await card.screenshot({ path: path.join(out, `test-tampering-${variant}-${scheme}.png`) });

            // The control's aria-controls target must disappear on close and return with the same
            // evidence on reopen. No wall-clock sleep is needed for this state transition.
            const bodyId = await disclosure.getAttribute("aria-controls");
            expect(bodyId).toBeTruthy();
            expect(await card.locator(".acpmux-tampering-body").getAttribute("id")).toBe(bodyId);
            await disclosure.click();
            await card.locator(".acpmux-tampering-body").waitFor({ state: "detached" });
            expect(await disclosure.getAttribute("aria-expanded")).toBe("false");
            await disclosure.click();
            await card.locator(".acpmux-tampering-body").waitFor();
            expect(await first.locator("pre del").textContent()).toBe("expect(response.status).toEqual(401)");
            expect(await evidence.count()).toBe(variant === "multiFile" ? 2 : 1);
            expect(errors).toEqual([]);
          } finally {
            await page.close();
          }
        });
  });
});
