#!/usr/bin/env node
// Renders the cmux-next agent pane of one webviews checkout and writes one PNG per
// scenario, theme and width. Swift-free: the pane runs from the checkout's own
// vite.config.acpmux-pane.mjs against the in-page mock daemon, replaying the
// checkout's recorded turns (webviews/scripts/agent-pane/*.json), the way
// compare:agent-pane does. Vite, Playwright and theme.mjs are loaded from the
// checkout, so the base and head of a PR each render with their own code.
//
//   node capture.mjs --webviews <checkout>/webviews --out DIR [--only NAME,...]
//                    [--engine chromium|webkit] [--channel chromium]
//
// --engine webkit renders in Playwright WebKit, the engine closest to the app's
// WKWebView (default chromium). --channel chromium launches full Chromium instead of
// the headless shell, which rounds glyph advances to whole pixels (tools/previews
// uses it on Linux with its measured stand-in fonts). Source of truth: cmuxterm-hq
// scripts/pr-preview/capture.mjs; this copy serves scripts/ci/pane-preview-webkit.sh.
//
// Writes DIR/<scenario>--<theme>--<width>.png and DIR/capture.json
// ({shots: {name: {ok, error?, ms}}}). A scenario that throws is recorded, not fatal:
// a PR that breaks one scenario still gets the others.
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";

const args = process.argv.slice(2);
const option = (name) => {
  const index = args.indexOf(`--${name}`);
  return index < 0 ? undefined : args[index + 1];
};
const webviews = path.resolve(option("webviews") ?? "webviews");
const out = path.resolve(option("out") ?? "out");
const only = option("only")?.split(",");
const concurrency = Number(option("jobs") ?? 6);
const engine = option("engine") ?? "chromium";
if (!["chromium", "webkit"].includes(engine)) throw new Error(`--engine must be chromium or webkit, got ${engine}`);
const channel = option("channel");
if (channel && engine !== "chromium") throw new Error(`--channel applies only to --engine chromium`);
fs.mkdirSync(out, { recursive: true });

const require = createRequire(path.join(webviews, "package.json"));
// A CommonJS package (playwright) arrives under `default` from a dynamic import.
const load = async (name) => {
  const module = await import(pathToFileURL(require.resolve(name)).href);
  return { ...module.default, ...module };
};
const { createServer } = await load("vite");
const playwright = await load("playwright");
const fixtures = path.join(webviews, "scripts/agent-pane");
const { agentPaneTheme, ghosttyDefault, ghosttyThemeFile } = await import(
  pathToFileURL(path.join(fixtures, "theme.mjs")).href
);

const themes = {
  default: () => ghosttyDefault,
  catppuccin: () => ghosttyThemeFile(path.resolve(webviews, "../Resources/ghostty/themes/Catppuccin Mocha")),
};
const widths = { normal: null, narrow: 420 };

/// Each scenario is a pane state worth a look in review. `fixture` replays a recorded
/// turn; without one the mock workspace opens as seeded. `then` drives the page after
/// the turn has drawn.
const scenarios = {
  transcript: {
    fixture: "worked-turn.json",
    size: { width: 1200, height: 1000 },
    then: async (page) => {
      await page.click(".cv-worked");
      await page.waitForSelector('.cv-worked[aria-expanded="true"]');
    },
  },
  subagents: {
    fixture: "summary-turn.json",
    size: { width: 1200, height: 800 },
    then: async (page) => {
      if (await page.$(".acpmux-summary-card")) return;
      await page.click(".acpmux-summary-button");
      await page.waitForSelector(".acpmux-summary-card");
    },
  },
  workspace: { size: { width: 1440, height: 900 } },
  composer: {
    size: { width: 1200, height: 800 },
    // The slash menu is the composer's busiest state: the input, its chips and a menu.
    // Composer.tsx: the prompt is a MarkdownField (class acpmux-composer-prompt) whose
    // ProseMirror editable carries role=combobox; the menu is #acpmux-slash-menu. The
    // fallbacks stay inside .acpmux-composer, for checkouts from before that markup.
    then: async (page) => {
      const prompt = '.acpmux-composer .acpmux-composer-prompt [contenteditable="true"]';
      const fallback = '.acpmux-composer [role="combobox"][contenteditable="true"], .acpmux-composer [contenteditable="true"], .acpmux-composer textarea';
      await page.waitForSelector(`${prompt}, ${fallback}`, { timeout: 10000 });
      const input = (await page.locator(prompt).count()) ? page.locator(prompt).first() : page.locator(fallback).first();
      await input.click();
      await page.keyboard.type("/");
      try {
        await page.waitForSelector('#acpmux-slash-menu, .acpmux-composer [role="listbox"]', { timeout: 4000 });
      } catch (error) {
        throw new Error(`the slash menu did not open: ${error?.message ?? error}`);
      }
    },
  },
};

const jobs = [];
for (const [name, scenario] of Object.entries(scenarios))
  for (const theme of Object.keys(themes))
    for (const [width, value] of Object.entries(widths)) {
      const shot = `${name}--${theme}--${width}`;
      if (!only || only.some((filter) => shot.includes(filter)))
        jobs.push({ shot, scenario, theme, size: { ...scenario.size, width: value ?? scenario.size.width } });
    }

const server = await createServer({
  configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
  // One-shot render: no file watcher (and no inotify watches to run out of).
  server: { port: 0, strictPort: false, watch: null, hmr: false },
  logLevel: "error",
});
await server.listen();
const url = server.resolvedUrls.local[0];
const report = { url, engine, channel: channel ?? null, shots: {} };
const browser = await playwright[engine].launch(channel ? { channel } : {});
try {
  // Warm Vite's transform cache once so the parallel pages don't all compile at once.
  const warm = await browser.newPage();
  await warm.goto(url, { waitUntil: "networkidle" }).catch(() => {});
  await warm.close();
  const queue = [...jobs];
  await Promise.all(
    Array.from({ length: Math.min(concurrency, queue.length) }, async () => {
      for (let job = queue.shift(); job; job = queue.shift()) {
        const started = Date.now();
        try {
          await capture(job);
          report.shots[job.shot] = { ok: true, ms: Date.now() - started };
        } catch (error) {
          report.shots[job.shot] = { ok: false, error: String(error?.message ?? error).slice(0, 500), ms: Date.now() - started };
        }
      }
    }),
  );
} finally {
  await browser.close();
  await server.close();
  fs.writeFileSync(path.join(out, "capture.json"), JSON.stringify(report, null, 2));
}
const failed = Object.entries(report.shots).filter(([, shot]) => !shot.ok);
console.log(`${jobs.length - failed.length}/${jobs.length} shots in ${out}`);
for (const [shot, { error }] of failed) console.log(`  ${shot}: ${error}`);

async function capture({ shot, scenario, theme, size }) {
  const fixture = scenario.fixture && JSON.parse(fs.readFileSync(path.join(fixtures, scenario.fixture), "utf8"));
  const context = await browser.newContext({ viewport: size, deviceScaleFactor: 2, colorScheme: "dark" });
  try {
    const page = await context.newPage();
    // Rows print their clock time; a fixed clock keeps an unchanged scenario byte-identical
    // between base and head. The mock daemon's timers still run.
    await page.clock.setFixedTime(new Date("2026-01-15T09:41:00"));
    const errors = [];
    page.on("pageerror", (error) => errors.push(error.message));
    await page.addInitScript(
      (script) => {
        if (script) window.cmuxAcpmuxMockScript = script;
        window.cmuxAcpmuxActions = { ready: async () => ({ protocolVersion: 1, transport: "mock" }) };
      },
      fixture && { steps: fixture.steps, endAtMs: fixture.endAtMs },
    );
    await page.goto(url, { waitUntil: "networkidle" });
    await page.waitForFunction(() => window.cmuxAcpmuxBridge && window.cmuxAcpmuxActions?.["chat.send"]);
    await page.evaluate((values) => window.cmuxAcpmuxBridge.applyTheme(values), agentPaneTheme(themes[theme]()));
    if (fixture) await page.evaluate((text) => window.cmuxAcpmuxActions["chat.send"]({ text }), fixture.prompt);
    await page.waitForFunction(() => document.querySelector('.acpmux-scroll [data-row-id^="summary-"]'), null, { timeout: 20000 });
    await page.evaluate(() => document.fonts.ready);
    if (scenario.then) await scenario.then(page);
    // Async work (syntax highlighting, chip measurement, transitions) lands after the turn
    // draws: keep shooting until two frames in a row match, so base and head compare
    // finished pages, not a race. A page that never settles is reported, not compared.
    let previous;
    let image;
    for (let attempt = 0; ; attempt++) {
      await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
      image = await page.screenshot({ animations: "disabled", caret: "hide" });
      if (previous?.equals(image)) break;
      if (attempt === 20) throw new Error("the page never settled (20 frames, 150 ms apart, all different)");
      previous = image;
      await page.waitForTimeout(150);
    }
    fs.writeFileSync(path.join(out, `${shot}.png`), image);
    if (errors.length) throw new Error(`the page threw: ${errors.join("; ")}`);
  } finally {
    await context.close();
  }
}
