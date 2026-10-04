// Drives bench/switch in headless Chromium against a dev slot and prints each stage.
//   node webviews/bench/switch/run.mjs --origin http://127.0.0.1:4192 --fragment '<dev-slot fragment>' \
//     [--modes before,after] [--steps codex,claude-sr,codex,opencode] [--hover 300] [--type 800] [--prompt TEXT] [--out FILE]
import fs from "node:fs";
import { chromium } from "playwright";

const argv = process.argv.slice(2);
const arg = (name, fallback) => {
  const index = argv.indexOf(`--${name}`);
  return index >= 0 ? argv[index + 1] : fallback;
};
const origin = arg("origin", "http://127.0.0.1:4192");
const fragment = arg("fragment");
const modes = arg("modes", "before,after").split(",");
const steps = arg("steps", "codex,claude-sr,codex,opencode").split(",");
const hoverMs = Number(arg("hover", 300));
const typeMs = Number(arg("type", 800));
const prompt = arg("prompt", "Reply with exactly: ok");
const out = arg("out");
const results = [];

const browser = await chromium.launch();
for (const mode of modes) {
  const page = await browser.newPage({ viewport: { width: 900, height: 600 } });
  page.on("pageerror", (error) => console.error(mode, "pageerror", error.message));
  await page.goto(`${origin}/bench/switch/?mode=${mode}#${fragment}`);
  await page.waitForFunction(() => window.__switch?.ready, null, { timeout: 90_000 });
  const boot = await page.evaluate(() => ({ catalogMs: window.__switch.catalogMs, marks: window.__switch.marks }));
  console.log(
    `[${mode}] catalog fetch ${boot.catalogMs.toFixed(0)} ms, initial ${boot.marks.find((m) => m.name === "initialReady")?.detail?.harness}`,
  );
  for (const harness of steps) {
    const from = await page.evaluate(() => window.__switch.harness);
    const start = await page.evaluate(() => window.__switch.marks.length);
    await page.hover(`button[data-harness="${harness}"]`);
    await page.waitForTimeout(hoverMs);
    await page.click(`button[data-harness="${harness}"]`);
    // The user types while the switch runs, or (before mode) once the new harness shows.
    if (mode === "before" && typeMs >= 0) {
      await page.waitForFunction(
        ([h, s]) =>
          window.__switch.marks.slice(s).some((m) => m.name === "sessionShown" && m.detail.harness === h) ||
          window.__switch.marks.slice(s).some((m) => m.name === "error"),
        [harness, start],
        { timeout: 120_000 },
      );
    } else await page.waitForTimeout(typeMs);
    await page.fill("#composer", prompt);
    await page.press("#composer", "Enter");
    await page
      .waitForFunction(
        (s) => window.__switch.marks.slice(s).some((m) => m.name === "firstToken" || m.name === "error"),
        start,
        { timeout: 180_000 },
      )
      .catch(() => undefined);
    await page.waitForFunction(() => !window.__switch.working, null, { timeout: 180_000 }).catch(() => undefined);
    const marks = await page.evaluate((s) => window.__switch.marks.slice(s), start);
    const at = (name, pred = () => true) => marks.find((m) => m.name === name && pred(m))?.at;
    const t0 = at("pick");
    const enter = at("enter");
    const row = {
      mode,
      from,
      harness,
      warm: marks.find((m) => m.name === "pick")?.detail?.warm,
      paint: (at("optimisticPaint") ?? at("sessionShown", (m) => m.detail.harness === harness)) - t0,
      sessionReady: (at("sessionShown", (m) => m.detail.harness === harness) ?? NaN) - t0,
      enterAfterPick: enter - t0,
      enterToSent: at("promptSent") - enter,
      enterToFirstToken: (at("firstToken") ?? NaN) - enter,
      sentTo: marks.find((m) => m.name === "promptSent")?.detail?.harness,
      error: marks.find((m) => m.name === "error")?.detail?.message,
    };
    results.push(row);
    const f = (v) => (Number.isFinite(v) ? `${v.toFixed(0)} ms` : "n/a");
    console.log(
      `[${mode}] ${from} -> ${harness}${row.warm ? " (warm)" : ""}: picker paints ${f(row.paint)}, session ready ${f(row.sessionReady)}, ` +
        `Enter at ${f(row.enterAfterPick)} -> sent ${f(row.enterToSent)} -> first token ${f(row.enterToFirstToken)} (sent to ${row.sentTo})${row.error ? " ERROR " + row.error : ""}`,
    );
    await page.waitForTimeout(500);
  }
  const warm = await page.evaluate(() =>
    [...document.querySelectorAll("button[data-warm=true]")].map((b) => b.dataset.harness),
  );
  console.log(`[${mode}] warm at end: ${warm.join(", ") || "none"}`);
  await page.close();
}
if (out) fs.writeFileSync(out, JSON.stringify(results, null, 2));
await browser.close();
