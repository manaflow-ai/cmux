// cmux-web-test-timeout: 240
// l10n-allow-file: deterministic Markdown regression fixtures.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("agent-pane-shell-math.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  const browsers = new Map<string, Browser>();
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browsers.set("chromium", await chromium.launch({ headless: true }));
    browsers.set("webkit", await webkit.launch({ headless: true }));
    await warmGalleryFrame(vite, "agent-pane.shell-math", {
      browser: browsers.get("chromium"),
      params: { variant: "transcript" },
    });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  for (const engine of ["chromium", "webkit"]) {
    for (const colorScheme of ["dark", "light"]) {
      test(`${engine} ${colorScheme}: shell text stays literal beside rendered equations`, async () => {
        const page = await browsers.get(engine)!.newPage({ viewport: { width: 900, height: 640 } });
        try {
          const port = (vite.httpServer!.address() as { port: number }).port;
          await page.goto(
            `http://127.0.0.1:${port}${galleryFrame("agent-pane.shell-math", {
              variant: "transcript",
              frame: "component",
              width: 900,
              height: 640,
              colorScheme,
            })}`,
          );
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
          await page.waitForFunction(() => document.querySelectorAll(".cv-md .katex").length >= 3);
          const answer = page.locator(".cv-md").filter({ hasText: "hybrid-ref-capture" }).first();
          if (process.env.CMUX_SHELL_MATH_CAPTURE && engine === "chromium") {
            const data = (await page.screenshot()).toString("base64");
            const name = `${process.env.CMUX_SHELL_MATH_CAPTURE}-${colorScheme}`;
            for (let at = 0; at < data.length; at += 4096)
              console.log(`SHELL_MATH_CAPTURE=${JSON.stringify({ name, at, data: data.slice(at, at + 4096) })}`);
          }
          expect(await answer.locator(".cv-math").count()).toBe(3);
          expect(await answer.textContent()).toContain('key="$(hybrid_ref_capture.py key .)"');
          expect(await answer.textContent()).toContain("name=hybrid-ref-capture-$key");
          expect(await answer.textContent()).toContain("$PATH and $HOME; cost $5 and $10; $(cmd); ${HOME}");
        } finally {
          await page.close();
        }
      });
    }
  }
});
