// l10n-allow-file: review evidence for the side panel's drag edge, no product wiring.
// Run on the fleet after gallery:build: opens a reply's table in the side panel (gallery entry
// agent-pane.artifact-panel#edge-rest), drags the panel's left edge toward the chat, and writes 2x
// captures plus the measured widths. Leo, 2026-11-09: "there's this supposed divider-looking thing that I
// can't actually drag".
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import assert from "node:assert/strict";
import { chromium, webkit } from "playwright";

const output = process.env.FAST_CHECKS_OUT;
if (!output) throw new Error("FAST_CHECKS_OUT must name the fleet artifact directory");
const gallery = path.resolve(import.meta.dir, "../../dist/gallery");
const out = path.join(output, "split-edge");
await mkdir(out, { recursive: true });
const server = Bun.serve({
  port: 0,
  async fetch(request) {
    const name = decodeURIComponent(new URL(request.url).pathname).replace(/^\/+/, "");
    const file = path.resolve(gallery, name || "index.html");
    if (!file.startsWith(`${gallery}/`)) return new Response("forbidden", { status: 403 });
    const blob = Bun.file(file);
    return (await blob.exists()) ? new Response(blob) : new Response("not found", { status: 404 });
  },
});
const results: Record<string, unknown>[] = [];
try {
  for (const engine of ["webkit", "chromium"] as const) {
    const browser = await (engine === "chromium"
      ? chromium.launch({ channel: "chrome", headless: true })
      : webkit.launch({ headless: true }));
    try {
      for (const scheme of ["dark", "light"] as const) {
        const context = await browser.newContext({
          viewport: { width: 1400, height: 820 },
          deviceScaleFactor: 2,
          colorScheme: scheme,
          reducedMotion: "reduce",
        });
        const page = await context.newPage();
        const source = "src/agent-session/acpmux/conversation/ArtifactPanel.gallery.ts";
        const params = new URLSearchParams({
          entry: "agent-pane.artifact-panel",
          variant: "edge-rest",
          source,
          entryPath: source,
          colorScheme: scheme,
          width: "1400",
          height: "820",
        });
        await page.goto(`http://127.0.0.1:${server.port}/frame.html?${params}`, { waitUntil: "domcontentloaded" });
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady, undefined, { timeout: 60_000 });
        assert.equal(await page.evaluate(() => document.documentElement.dataset.galleryReady), "1");
        const panel = page.locator(".acpmux-artifact");
        const edge = page.locator(".acpmux-artifact > .ui-split-edge");
        await edge.waitFor({ state: "attached", timeout: 10_000 });
        const name = `${engine}-${scheme}`;
        const before = (await panel.boundingBox())!;
        await page.screenshot({ path: path.join(out, `${name}-1-open.png`) });
        const grip = (await edge.boundingBox())!;
        const x = grip.x + grip.width / 2;
        const y = grip.y + grip.height / 2;
        await page.mouse.move(x, y);
        const cursor = await edge.evaluate((node) => getComputedStyle(node).cursor);
        await page.screenshot({ path: path.join(out, `${name}-2-hover.png`) });
        await page.mouse.down();
        for (let step = 1; step <= 10; step++) await page.mouse.move(x - step * 20, y);
        await page.screenshot({ path: path.join(out, `${name}-3-dragging.png`) });
        await page.mouse.up();
        await page.waitForTimeout(100);
        const after = (await panel.boundingBox())!;
        await page.screenshot({ path: path.join(out, `${name}-4-dragged.png`) });
        const saved = await page.evaluate(() => localStorage.getItem("cmux.agentPane.artifact.share"));
        const result = { engine, scheme, before: before.width, after: after.width, cursor, saved };
        results.push(result);
        assert.equal(cursor, "col-resize");
        assert.ok(after.width - before.width > 150, `panel did not widen: ${JSON.stringify(result)}`);
        await context.close();
      }
    } finally {
      await browser.close();
    }
  }
} finally {
  await writeFile(path.join(out, "results.json"), JSON.stringify(results, null, 2));
  server.stop(true);
}
console.log(JSON.stringify(results));
