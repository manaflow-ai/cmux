// l10n-allow-file: gallery evidence capture, no product strings.
// Captures Session Info Storage gallery variants to $FAST_CHECKS_OUT.
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { chromium } from "playwright";
const out = path.join(process.env.FAST_CHECKS_OUT!, "storage");
await mkdir(out, { recursive: true });
const gallery = path.resolve(process.argv[2]!);
const server = Bun.serve({ port: 0, async fetch(r) {
  const name = decodeURIComponent(new URL(r.url).pathname).replace(/^\/+/, "");
  const f = Bun.file(path.resolve(gallery, name || "index.html"));
  return (await f.exists()) ? new Response(f) : new Response("nf", { status: 404 });
}});
const browser = await chromium.launch({ headless: true });
for (const scheme of ["dark", "light"]) for (const v of ["a-plain","b-grouped","c-summary","loading","empty","many-rows","errors","freeing","freed"]) {
  if (scheme === "light" && !["c-summary","freed"].includes(v)) continue;
  const ctx = await browser.newContext({ viewport: { width: 320, height: 560 }, deviceScaleFactor: 2, colorScheme: scheme as "dark"|"light", reducedMotion: "reduce" });
  const page = await ctx.newPage();
  const src = "src/agent-session/acpmux/session-info/StorageSection.gallery.tsx";
  const p = new URLSearchParams({ entry: "agent-pane.session-info-storage", variant: v, source: src, entryPath: src,
    theme: scheme === "light" ? "Apple System Colors Light" : "Apple System Colors", colorScheme: scheme, reducedMotion: "true", width: "320", height: "560" });
  try {
    await page.goto(`http://127.0.0.1:${server.port}/frame.html?${p}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, { timeout: 30000 });
    await page.evaluate(() => document.fonts.ready);
    await page.waitForTimeout(400);
    await page.screenshot({ path: path.join(out, `${scheme}-${v}.png`) });
  } catch (e) { console.log("FAIL", v, String(e).slice(0, 300)); }
  await ctx.close();
}
await browser.close(); server.stop(); console.log("done");
