// The resident UI preview worker's web shots (scripts/cmux-next/ui-preview-worker.py): gallery entries from the
// live gallery dev server the worker keeps running (`bun run gallery:dev`), one PNG each, headless.
//
//   bun scripts/cmux-next/ui-preview-shoot.mjs SPEC.json OUT_DIR        (cwd: the worker's web tree's webviews/)
//   bun scripts/cmux-next/ui-preview-shoot.mjs --serve                  (one chromium kept open between looks)
//   SPEC.json: {"base": "http://127.0.0.1:4217/gallery/", "scheme": "dark",
//               "shots": [{"name": "agent-pane.composer", "entry": "agent-pane.composer", "variant": "…"}]}
//
// SPEC OUT prints one JSON line a shot: {name, file} or {name, error}; exit 1 when every shot failed. --serve reads
// one spec a line on stdin (with "out", the folder) and answers each with one line {"shots": [{name, file} | {name,
// error}]}, so a look pays no chromium launch (the worker's cold shoot was most of a look); it exits when stdin
// closes. Playwright is resolved from the working directory (the web tree's node_modules), not from this file's
// checkout.
import fs from "node:fs";
import path from "node:path";
import readline from "node:readline";
import { createRequire } from "node:module";

const require = createRequire(path.join(process.cwd(), "package.json"));
const { chromium } = require("playwright");
const browser = await chromium.launch({ channel: "chrome" }).catch(() => chromium.launch());

async function shoot(spec, out) {
  fs.mkdirSync(out, { recursive: true });
  const scheme = spec.scheme ?? "dark";
  const context = await browser.newContext({
    viewport: { width: spec.width ?? 760, height: spec.height ?? 480 },
    deviceScaleFactor: spec.deviceScaleFactor ?? 2,
    colorScheme: scheme,
  });
  try {
    // One page per shot, all at once: the dev server transforms each entry's modules on first request.
    return await Promise.all(
      (spec.shots ?? []).map(async (shot) => {
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
          return { name: shot.name, file };
        } catch (error) {
          return { name: shot.name, error: String(error).slice(0, 300) };
        } finally {
          await page.close().catch(() => {});
        }
      }),
    );
  } finally {
    await context.close().catch(() => {});
  }
}

if (process.argv[2] === "--serve") {
  const lines = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
  for await (const line of lines) {
    if (!line.trim()) continue;
    let answer;
    try {
      const spec = JSON.parse(line);
      answer = { shots: await shoot(spec, path.resolve(spec.out)) };
    } catch (error) {
      answer = { shots: [], error: String(error).slice(0, 300) };
    }
    process.stdout.write(JSON.stringify(answer) + "\n");
  }
  await browser.close();
  process.exit(0);
} else {
  const spec = JSON.parse(fs.readFileSync(path.resolve(process.argv[2]), "utf8"));
  let rows = [];
  try {
    rows = await shoot(spec, path.resolve(process.argv[3]));
  } finally {
    await browser.close();
  }
  for (const row of rows) console.log(JSON.stringify(row));
  process.exit(rows.some((r) => r.file) || rows.length === 0 ? 0 : 1);
}
