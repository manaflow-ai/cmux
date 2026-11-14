// cmux-web-test-timeout: 300
// The composer hat's × (question/HatQuestions.tsx) is muted, as the pager beside it is, and takes the
// text colour only on hover or focus. Its rule once had one class and lost to the shared button's
// `.ui-button.ui-btn { color: var(--ds-color-fg) }` (ui/controls.css), so the × showed at full
// contrast. It renders the gallery stage `agent-pane.hat-questions` (variant `dismiss-always`, the ×
// shown at rest) in Chromium and compares the ×'s computed colour with the pager's muted one.
// CI fails the file when it cannot launch (requireBrowserLane). Locally:
// CMUX_BROWSER_TESTS=1 bun test test/hat-questions-dismiss-muted.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("hat-questions-dismiss-muted.test.ts", async () => {
  const ENTRY = "agent-pane.hat-questions";
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("hat questions dismiss muted", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
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
    await warmGalleryFrame(vite, [ENTRY], { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const theme of ["Apple System Colors", "Apple System Colors Light"]) {
    test(`${theme}: the × is muted at rest and takes the text colour on hover`, async () => {
      const page = await browser!.newPage({ viewport: { width: 640, height: 560 } });
      try {
        const port = (vite!.httpServer!.address() as { port: number }).port;
        await page.goto(
          `http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: "dismiss-always", frame: "component", width: 640, theme })}`,
        );
        const close = page.locator(".acpmux-hat-questions__dismiss");
        await close.waitFor({ state: "visible" });
        const colors = () =>
          page.evaluate(() => {
            const of = (selector: string) => {
              const element = document.querySelector(selector);
              return element ? getComputedStyle(element).color : "";
            };
            const probe = document.createElement("span");
            document.body.append(probe);
            probe.style.color = "var(--agent-text)";
            const text = getComputedStyle(probe).color;
            probe.style.color = "var(--agent-muted)";
            const muted = getComputedStyle(probe).color;
            probe.remove();
            return { close: of(".acpmux-hat-questions__dismiss"), muted, text };
          });
        const rest = await colors();
        expect(rest.muted).not.toBe(rest.text);
        expect(rest.close).toBe(rest.muted);
        await close.hover();
        await page.waitForFunction(
          (text) => getComputedStyle(document.querySelector(".acpmux-hat-questions__dismiss")!).color === text,
          rest.text,
        );
      } finally {
        await page.close();
      }
    });
  }
});
