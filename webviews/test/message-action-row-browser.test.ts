import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { mkdir } from "node:fs/promises";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";
import { installPaintedFrames } from "./support/paintedFrames";

await requireBrowserLane("message-action-row-browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  let page: Page;
  beforeAll(async () => {
    const root = path.resolve(import.meta.dir, "..");
    vite = await createServer({
      root,
      configFile: path.join(root, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1" },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/message-action-row.html");
    browser = await chromium.launch({ headless: true });
    page = await browser.newPage({ viewport: { width: 760, height: 430 } });
    await installPaintedFrames(page);
    page.on("pageerror", (error) => console.error(error));
    await page.goto(
      `http://127.0.0.1:${(vite.httpServer!.address() as { port: number }).port}/test/browser/message-action-row.html`,
    );
    await page.locator('[data-message-kind="received"]').waitFor();

    if (process.env.CMUX_ACTION_CAPTURE) {
      await mkdir(process.env.CMUX_ACTION_CAPTURE, { recursive: true });
      await page.screenshot({ path: path.join(process.env.CMUX_ACTION_CAPTURE, "actions.png") });
    }
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("all message kinds use equal 24px hit boxes, 16px icons and contiguous controls", async () => {
    const rows = await page.evaluate(
      () =>
        new Promise<
          {
            kind: string;
            buttons: { width: number; height: number; iconWidth: number; iconHeight: number; gap: number | null }[];
          }[]
        >((done) => {
          window.cmuxAfterPaint(() => {
            done(
              [...document.querySelectorAll<HTMLElement>("[data-message-kind]")].map((row) => {
                let previous: DOMRect | undefined;
                return {
                  kind: row.dataset.messageKind!,
                  buttons: [...row.querySelectorAll<HTMLButtonElement>("button.cv-iconbtn")].map((button) => {
                    const box = button.getBoundingClientRect();
                    const icon = button.querySelector("svg, [data-symbol]")!.getBoundingClientRect();
                    const gap = previous ? box.left - previous.right : null;
                    previous = box;
                    return {
                      width: box.width,
                      height: box.height,
                      iconWidth: icon.width,
                      iconHeight: icon.height,
                      gap,
                    };
                  }),
                };
              }),
            );
            return false;
          });
        }),
    );
    expect(rows.map((row) => row.kind)).toEqual(["user", "assistant", "received", "sent"]);
    for (const row of rows) {
      expect(row.buttons.length).toBeGreaterThan(0);
      for (const button of row.buttons) {
        expect(button.width).toBe(24);
        expect(button.height).toBe(24);
        expect(button.iconWidth).toBe(16);
        expect(button.iconHeight).toBe(16);
        if (button.gap !== null) expect(button.gap).toBe(0);
      }
    }
  });

  test("keyboard retry sends the original prompt and model selection remains usable", async () => {
    const user = page.locator('[data-message-kind="user"]');
    await user.getByRole("button", { name: "Retry", exact: true }).focus();
    await page.keyboard.press("Enter");
    await page.getByText("Retried action-prompt", { exact: true }).waitFor();
    await user.getByRole("button", { name: "Retry with another model" }).click();
    await page.getByRole("menuitemradio", { name: "Model B" }).click();
    await page.getByText("Retried action-prompt with model-b", { exact: true }).waitFor();
  });
});
