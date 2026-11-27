import { test, setDefaultTimeout } from "bun:test";
import path from "node:path";
import { writeFileSync, appendFileSync } from "node:fs";
import { chromium } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { loadEntries } from "../scripts/gallery/entries";
setDefaultTimeout(6 * 3600_000);
test("explore", async () => {
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  const vite = await createServer({ configFile: path.join(webviews, "vite.config.gallery-dev.ts"), server: { port: 0, host: "127.0.0.1", watch: { ignored: () => true } }, logLevel: "error" });
  await vite.listen();
  const browser = await chromium.launch({ headless: true });
  const port = (vite.httpServer!.address() as { port: number }).port;
  const entries = await loadEntries();
  const shard = Number(process.env.SHARD ?? 0), shards = Number(process.env.SHARDS ?? 1);
  const out = `/tmp/uiexp/out-${shard}.jsonl`; writeFileSync(out, "");
  let i = 0;
  for (const entry of entries.filter((e) => new RegExp(process.env.ONLY ?? ".").test(e.id))) {
    if (i++ % shards !== shard) continue;
    const variant = Object.keys(entry.variants)[0]!;
    const page = await browser.newPage({ viewport: { width: entry.widths ? (Object.values(entry.widths)[1] as number ?? 600) : 600, height: 700 } });
    try {
      await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry.id, { variant })}`, { timeout: 60000 });
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady, undefined, { timeout: 25000 });
      await page.waitForTimeout(400);
      const v = await page.evaluate(() => (window as any).cmuxGalleryInvariants?.() ?? null);
      appendFileSync(out, JSON.stringify({ id: entry.id, variant, v }) + "\n");
    } catch (e) { appendFileSync(out, JSON.stringify({ id: entry.id, variant, err: String(e).slice(0, 120) }) + "\n"); }
    finally { await page.close(); }
  }
  await browser.close(); await vite.close();
});
