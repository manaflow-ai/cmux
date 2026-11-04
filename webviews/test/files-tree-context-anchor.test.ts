// cmux-web-test-timeout: 240
// A right-click on a diff-tree file row anchors its menu at the pointer, in headless Chromium on the
// latency harness's diff page. `#files-sidebar` has a transform and `contain: strict`, so it is the
// containing block of the `position: fixed` anchor (FilesSidebar.tsx); viewport coordinates put the
// anchor (and the menu the host draws at it) one sidebar offset away from the click.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { spawn, type ChildProcess } from "node:child_process";
import net from "node:net";
import path from "node:path";
import { chromium } from "playwright";
import { stopDevServer } from "./support/devServer";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmDevServer } from "./support/warmDevServer";

await requireBrowserLane("files-tree-context-anchor.test.ts", async () => {
  setDefaultTimeout(120_000);
  const webviews = path.resolve(import.meta.dir, "..");
  let server: ChildProcess | null = null;
  let base = "";

  beforeAll(async () => {
    const port = await new Promise<number>((resolve) => {
      const probe = net.createServer().listen(0, "127.0.0.1", () => {
        const { port } = probe.address() as net.AddressInfo;
        probe.close(() => resolve(port));
      });
    });
    server = spawn(path.join(webviews, "node_modules/.bin/vp"), ["dev", "--port", String(port), "--strictPort"], {
      cwd: webviews,
      stdio: ["ignore", "pipe", "pipe"],
    });
    base = `http://127.0.0.1:${port}`;
    await new Promise<void>((resolve, reject) => {
      const onData = (chunk: Buffer) =>
        String(chunk)
          // oxlint-disable-next-line no-control-regex -- strips ANSI color escapes
          .replace(/\x1b\[[0-9;]*m/g, "")
          .includes(`127.0.0.1:${port}`)
          ? resolve()
          : undefined;
      server!.stdout!.on("data", onData);
      server!.stderr!.on("data", onData);
      server!.on("exit", (code) => reject(new Error(`dev server exited ${code}`)));
    });
    await warmDevServer(base, "/test/latency/diff.html");
  }, 240_000);

  afterAll(() => {
    stopDevServer(server);
  });

  describe("diff tree context menu", () => {
    test("the anchor sits at the right-click point", async () => {
      const browser = await chromium.launch({ headless: true });
      try {
        const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
        await page.goto(`${base}/test/latency/diff.html`);
        await page.waitForFunction(() => document.body.dataset.streamFileCount === "240", undefined, {
          timeout: 30_000,
        });
        const point = await page.evaluate(() => {
          const row = document
            .querySelector("file-tree-container")
            ?.shadowRoot?.querySelector<HTMLElement>('[data-item-path="src/area00/file000.ts"]');
          if (!row) return null;
          const rect = row.getBoundingClientRect();
          return { x: Math.round(rect.left + rect.width / 2), y: Math.round(rect.top + rect.height / 2) };
        });
        expect(point).not.toBeNull();
        const sidebar = await page.evaluate(() => document.querySelector("#files-sidebar")!.getBoundingClientRect().left);
        // The panel sits at the right, so a viewport-placed anchor would land a sidebar offset away.
        expect(sidebar).toBeGreaterThan(100);
        await page.mouse.click(point!.x, point!.y, { button: "right" });
        await page.waitForSelector(".file-tree-context-anchor", { state: "attached", timeout: 10_000 });
        const anchor = await page.evaluate(() => {
          const rect = document.querySelector(".file-tree-context-anchor")!.getBoundingClientRect();
          return { x: Math.round(rect.left), y: Math.round(rect.top) };
        });
        expect(anchor).toEqual(point!);
      } finally {
        await browser.close();
      }
    });
  });
});
