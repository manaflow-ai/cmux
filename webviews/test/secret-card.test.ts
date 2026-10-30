// An agent asks for a secret (cx-ncc.42): the pane shows a private card above the composer, the
// person types the value and Provide hands it to acpmux only. The transcript gallery's secret-card
// play fills the real card in Chromium; this checks the play passed, what the page sent, and that
// the value never showed in the page.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("secret-card.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("secret-card: skipping (run `bunx playwright install chromium`)");
    describe.skip("secret card", () => test("chromium", () => {}));
    return;
  }

  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;

  const stageURL = (variant: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame("agent-pane.transcript", { variant })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "agent-pane.transcript", { browser, params: { variant: "secret-card" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const play = async (variant: string) => {
    const page = await browser!.newPage({ viewport: { width: 760, height: 560 } });
    await page.goto(stageURL(variant));
    await page.waitForFunction(() => {
      const ready = document.documentElement.dataset.galleryReady;
      return ready === "1" || ready === "error";
    });
    await page.waitForFunction(() => Boolean(document.documentElement.dataset.galleryPlay));
    const result = await page.evaluate(() => ({
      play: document.documentElement.dataset.galleryPlay,
      report: JSON.stringify((window as unknown as { cmuxGalleryPlayReport?: unknown }).cmuxGalleryPlayReport),
      answers: (
        window as unknown as { cmuxGalleryLog: { method: string; params?: Record<string, unknown> }[] }
      ).cmuxGalleryLog
        .filter(({ method }) => method === "chat.secret")
        .map(({ params }) => params),
      pageText: document.body.innerText,
      fields: [...document.querySelectorAll("input")].map((input) => input.value),
    }));
    await page.close();
    return result;
  };

  test("the card takes the value privately and Provide sends it to acpmux only", async () => {
    const result = await play("secret-card");
    expect(result.play, result.report).toBe("pass");
    expect(result.answers).toEqual([{ secretId: "gallery-secret", value: "sk-test-51Hx9" }]);
    expect(result.pageText).not.toContain("sk-test-51Hx9");
    expect(result.fields).not.toContain("sk-test-51Hx9");
  });
});
