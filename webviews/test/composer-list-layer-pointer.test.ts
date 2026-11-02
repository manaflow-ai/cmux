// The `/` and `@` lists' layer (backdropLayer.tsx) lies over the composer card, out of its glass.
// In the floating dock (bottomStack.css) every child of the composer takes the pointer, and that
// rule outranked the layer's own `pointer-events: none`: while a list was open the layer covered
// the card and a click on the prompt or its buttons reached the layer instead. Only the list in the
// layer takes the pointer; the card under the rest of it does.
//
// The page is the real agent pane (`?mock`: the in-page mock daemon) in Chromium from Playwright.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { spawn, type ChildProcess } from "node:child_process";
import net from "node:net";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { stopDevServer } from "./support/devServer";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmDevServer } from "./support/warmDevServer";

await requireBrowserLane("composer-list-layer-pointer.test.ts", async () => {
  setDefaultTimeout(120_000);
  const webviews = path.resolve(import.meta.dir, "..");
  let installed = true;
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    installed = false;
    console.warn("composer-list-layer-pointer: skipping (run `bunx playwright install chromium`)");
  }

  let server: ChildProcess | null = null;
  let browser: Browser | null = null;
  let base = "";

  beforeAll(async () => {
    if (!installed) return;
    const port = await new Promise<number>((resolve) => {
      const probe = net.createServer().listen(0, "127.0.0.1", () => {
        const { port } = probe.address() as net.AddressInfo;
        probe.close(() => resolve(port));
      });
    });
    server = spawn(
      path.join(webviews, "node_modules/.bin/vp"),
      ["dev", "--config", "vite.config.acpmux-pane.mjs", "--port", String(port), "--strictPort"],
      { cwd: webviews, stdio: ["ignore", "pipe", "pipe"] },
    );
    base = `http://127.0.0.1:${port}`;
    await new Promise<void>((resolve, reject) => {
      const onData = (chunk: Buffer) => (String(chunk).includes(`${port}`) ? resolve() : undefined);
      server!.stdout!.on("data", onData);
      server!.stderr!.on("data", onData);
      server!.on("exit", (code) => reject(new Error(`dev server exited ${code}`)));
    });
    await warmDevServer(base, "/?mock");
    browser = await chromium.launch({ headless: true });
  }, 240_000);

  afterAll(async () => {
    await browser?.close();
    stopDevServer(server);
  });

  /** The pane with the composer's list open by typing `trigger` into an empty prompt. */
  async function opened(trigger: "/" | "@"): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: 1000, height: 800 } });
    await page.goto(`${base}/?mock`);
    const prompt = page.locator(".acpmux-composer-box [contenteditable='true']").first();
    await prompt.click();
    await page.keyboard.type(trigger);
    await page.locator(trigger === "/" ? "#acpmux-slash-menu" : "#acpmux-mention-menu").waitFor();
    return page;
  }

  /** What a press at the card's middle and at its left edge would reach. */
  const reached = (page: Page) =>
    page.evaluate(() => {
      const box = document.querySelector(".acpmux-composer-box")!.getBoundingClientRect();
      const at = (x: number) => document.elementFromPoint(x, box.top + box.height / 2);
      return [at(box.left + box.width / 2), at(box.left + 12)].map((node) => ({
        card: node?.closest(".acpmux-composer-box") !== null && node?.closest(".acpmux-composer-box") !== undefined,
        layer:
          node?.closest(".acpmux-composer-list-layer") !== null &&
          node?.closest(".acpmux-composer-list-layer") !== undefined,
      }));
    });

  describe.skipIf(!installed)("the list layer passes the pointer to the card", () => {
    for (const trigger of ["/", "@"] as const)
      test(`with the ${trigger} list open, a press on the card reaches the card`, async () => {
        const page = await opened(trigger);
        expect(await page.evaluate(() => document.querySelector(".acpmux-main")?.getAttribute("data-dock"))).toBe(
          "float",
        );
        for (const spot of await reached(page)) expect(spot).toEqual({ card: true, layer: false });
        await page.close();
      });
  });
});
