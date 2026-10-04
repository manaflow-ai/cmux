// Runs bench/stream (index.html) headless in Chromium and WebKit and writes one JSON per run.
//   node webviews/bench/stream/run-bench.mjs --origin http://127.0.0.1:4188 --out DIR \
//     [--engines chromium,webkit] [--modes before,after] [--fixtures claude,codex] [--limit MS] [--shots DIR]
//     [--query 'hz=60&reduced'] [--tag -60hz]
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { chromium, webkit } from "playwright";

const here = path.dirname(fileURLToPath(import.meta.url));
const argv = process.argv.slice(2);
const arg = (name, fallback) => {
  const index = argv.indexOf(`--${name}`);
  return index >= 0 ? argv[index + 1] : fallback;
};
const origin = arg("origin", "http://127.0.0.1:4188");
const out = arg("out", "/tmp/acp-stream-bench");
const shots = arg("shots");
const engines = arg("engines", "chromium,webkit").split(",");
const modes = arg("modes", "before,after").split(",");
const fixtures = arg("fixtures", "claude,codex").split(",");
const limit = arg("limit");
const extra = arg("query", "");
const tag = arg("tag", "");
fs.mkdirSync(out, { recursive: true });
if (shots) fs.mkdirSync(shots, { recursive: true });

for (const engineName of engines) {
  const browser = await (engineName === "webkit" ? webkit : chromium).launch({ headless: true });
  for (const fixture of fixtures)
    for (const mode of modes) {
      const page = await browser.newPage({ viewport: { width: 900, height: 900 }, deviceScaleFactor: 2 });
      await page.addInitScript({ path: path.join(here, "instrument.js") });
      page.on("pageerror", (error) => console.error(engineName, mode, "pageerror", error.message));
      const query = `mode=${mode}&fixture=${fixture}${limit ? `&limit=${limit}` : ""}${extra ? `&${extra}` : ""}`;
      const cdp = engineName === "chromium" ? await page.context().newCDPSession(page) : undefined;
      if (cdp) await cdp.send("Performance.enable");
      const metric = async () =>
        cdp ? Object.fromEntries((await cdp.send("Performance.getMetrics")).metrics.map((m) => [m.name, m.value])) : {};
      await page.goto(`${origin}/bench/stream/?${query}`);
      if (mode === "parse") {
        await page.waitForFunction(() => window.__stream?.done, null, { timeout: 300_000 });
        const parse = await page.evaluate(() => window.__stream.parse);
        fs.writeFileSync(path.join(out, `parse-${fixture}-${engineName}.json`), JSON.stringify(parse));
        console.log(engineName, fixture, "parse", JSON.stringify(parse));
        await page.close();
        continue;
      }
      await page.evaluate(() => {
        window.__stream.phase = "pinned";
      });
      const before = await metric();
      let scrolled = false;
      let shot = 0;
      while (true) {
        const state = await page.evaluate(() => ({
          done: Boolean(window.__stream.done),
          chunks: window.__stream.ws.length,
          code: document.querySelectorAll(".cv-codeblock").length,
        }));
        if (shots && state.chunks > 0 && !scrolled && shot < 24) {
          await page.screenshot({
            path: path.join(
              shots,
              `acp-stream-bench-${fixture}-${mode}-${engineName}-${String(shot).padStart(2, "0")}.png`,
            ),
          });
          shot += 1;
        }
        if (!scrolled && state.chunks > (fixture === "codex" ? 400 : 300) && state.code >= 2) {
          scrolled = await page.evaluate(() => window.__streamScrollUp(500));
        }
        if (state.done) break;
        await page.waitForTimeout(200);
      }
      await page.waitForTimeout(400);
      const after = await metric();
      const cpu = Object.fromEntries(
        ["TaskDuration", "ScriptDuration", "LayoutDuration", "RecalcStyleDuration", "LayoutCount", "RecalcStyleCount"]
          .filter((key) => key in after)
          .map((key) => [key, Math.round((after[key] - before[key]) * (key.endsWith("Count") ? 1 : 1000))]),
      );
      const result = await page.evaluate(() => {
        const m = window.__stream;
        return {
          ws: m.ws,
          frames: m.frames,
          paints: m.paints,
          blocks: m.blocks,
          edge: m.edge,
          pin: m.pin,
          anchor: m.anchor,
          code: m.code,
          shifts: m.shifts,
          longtasks: m.longtasks,
          react: m.react,
        };
      });
      const file = path.join(out, `bench-${fixture}-${mode}${tag}-${engineName}.json`);
      fs.writeFileSync(
        file,
        JSON.stringify({ harness: `${fixture}-${mode}${tag}`, engine: engineName, cpu, ...result }),
      );
      console.log("wrote", file);
      await page.close();
    }
  await browser.close();
}
