// The resident UI preview worker's web shots (scripts/cmux-next/ui-preview-worker.py): gallery entries from the
// live gallery dev server the worker keeps running (`bun run gallery:dev`), one PNG each, headless.
//
//   bun scripts/cmux-next/ui-preview-shoot.mjs SPEC.json OUT_DIR        (cwd: the worker's web tree's webviews/)
//   SPEC.json: {"base": "http://127.0.0.1:4217/gallery/", "scheme": "dark",
//               "shots": [{"name": "agent-pane.composer", "entry": "agent-pane.composer", "variant": "…"}]}
//
// Prints one JSON line a shot: {name, file} or {name, error}; exit 1 when every shot failed. Playwright is resolved
// from the working directory (the web tree's node_modules), not from this file's checkout.
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";

const spec = JSON.parse(fs.readFileSync(path.resolve(process.argv[2]), "utf8"));
const out = path.resolve(process.argv[3]);
fs.mkdirSync(out, { recursive: true });
const require = createRequire(path.join(process.cwd(), "package.json"));
const { chromium } = require("playwright");
const scheme = spec.scheme ?? "dark";

const browser = await chromium.launch({ channel: "chrome" }).catch(() => chromium.launch());
let ok = 0;
try {
  const context = await browser.newContext({
    viewport: { width: spec.width ?? 760, height: spec.height ?? 480 },
    deviceScaleFactor: spec.deviceScaleFactor ?? 2,
    colorScheme: scheme,
  });
  // One page per shot, all at once: the dev server transforms each entry's modules on first request.
  await Promise.all(
    spec.shots.map(async (shot) => {
      const page = await context.newPage();
      const query = new URLSearchParams({ entry: shot.entry, colorScheme: scheme, width: "narrow", frame: "component" });
      if (shot.variant) query.set("variant", shot.variant);
      const file = `${shot.name.replace(/[^A-Za-z0-9._-]/g, "_")}.png`;
      try {
        await page.goto(`${spec.base}frame.html?${query}`, { waitUntil: "domcontentloaded" });
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
          timeout: 60_000,
        });
        await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(r, 300)))));
        await page.screenshot({ path: path.join(out, file) });
        ok += 1;
        console.log(JSON.stringify({ name: shot.name, file }));
      } catch (error) {
        console.log(JSON.stringify({ name: shot.name, error: String(error).slice(0, 300) }));
      }
      await page.close();
    }),
  );
} finally {
  await browser.close();
}
process.exit(ok > 0 || spec.shots.length === 0 ? 0 : 1);
