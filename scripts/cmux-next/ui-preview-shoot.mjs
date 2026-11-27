// The resident UI preview worker's web shots (scripts/cmux-next/ui-preview-worker.py): gallery entries from the
// live gallery dev server the worker keeps running (`bun run gallery:dev`), one PNG each, headless.
//
//   bun scripts/cmux-next/ui-preview-shoot.mjs SPEC.json OUT_DIR        (cwd: the worker's web tree's webviews/)
//   bun scripts/cmux-next/ui-preview-shoot.mjs --serve                  (one chromium kept open between looks)
//   SPEC.json: {"base": "http://127.0.0.1:4217/gallery/", "scheme": "dark",
//               "try_ms": 20000, "bound_ms": 60000,
//               "shots": [{"name": "agent-pane.composer", "entry": "agent-pane.composer", "variant": "…"},
//                         {"name": "new.entry", "entry": "new.entry", "absent": "<sha12>"}]}
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

// The frame at URL until it marks itself ready ("1"), within BOUND ms. A frame that marks "error" fails at once (its
// message is the error). A page that has not marked anything after TRY ms is reloaded and waited on again: one loaded
// while vite restarted its server or re-optimized its deps (a checkout that changes them) never marks ready.
async function ready(page, url, tryMs, boundMs) {
  const deadline = Date.now() + boundMs;
  let loaded = false;
  for (let attempt = 1; ; attempt++) {
    const left = deadline - Date.now();
    if (left <= 0) throw new Error(`the frame did not mark ready in ${boundMs} ms (${attempt - 1} tries)`);
    try {
      if (loaded) await page.reload({ waitUntil: "domcontentloaded", timeout: left });
      else await page.goto(url, { waitUntil: "domcontentloaded", timeout: left });
      loaded = true;
      const mark = await page.waitForFunction(
        () => {
          const state = document.documentElement.dataset.galleryReady;
          return state === "1" || state === "error" ? state : false;
        },
        undefined,
        { timeout: Math.min(tryMs, Math.max(1, deadline - Date.now())) },
      );
      if ((await mark.jsonValue()) === "error") {
        const text = await page.evaluate(() => document.body.textContent ?? "").catch(() => "");
        throw Object.assign(new Error(`the frame failed: ${text.slice(0, 200)}`), { final: true });
      }
      return attempt;
    } catch (error) {
      if (error?.final) throw error;
      // A timeout, or a navigation vite's restart cut short (ERR_CONNECTION_RESET while
      // the server comes back): pause so a down server is not hammered, then reload and
      // wait again, inside the bound.
      await new Promise((resolve) => setTimeout(resolve, Math.min(500, Math.max(0, deadline - Date.now()))));
    }
  }
}

function absentCard(entry, sha, scheme) {
  const esc = (t) => String(t).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
  const [bg, fg, dim] = scheme === "light" ? ["#ffffff", "#1d1d1f", "#6e6e73"] : ["#1e1e1e", "#f5f5f7", "#98989d"];
  return `<!doctype html><html><body style="margin:0;height:100vh;display:grid;place-items:center;background:${bg};
    font:15px -apple-system,system-ui,sans-serif;color:${fg}"><div style="text-align:center">
    <div style="font-weight:600">${esc(entry)}</div>
    <div style="color:${dim};margin-top:6px">not in commit ${esc(sha)}</div></div></body></html>`;
}

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
        const safe = shot.name.replace(/[^A-Za-z0-9._-]/g, "_");
        const file = shot.absent ? `absent.${safe}.png` : `${safe}.png`;
        const started = Date.now();
        let tries = 0;
        try {
          if (shot.absent) {
            // The entry is not in this checkout (the push adds or removes it): a card that says so, no frame.
            await page.setContent(absentCard(shot.entry, shot.absent, scheme));
          } else {
            tries = await ready(page, `${spec.base}frame.html?${query}`, spec.try_ms ?? 20_000, spec.bound_ms ?? 60_000);
          }
          await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(r, 300)))));
          await page.screenshot({ path: path.join(out, file) });
          return { name: shot.name, file, ms: Date.now() - started, tries };
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
