#!/usr/bin/env node
// Renders the agent pane in mock mode and scores it against a native capture.
//
//   node scripts/agent-pane/compare.mjs [scenario ...] [--atlas DIR] [--out DIR]
//
// The pane runs from the dev server config (vite.config.acpmux-pane.mjs) with the
// host bridge stubbed: `ready` answers mock, so the production client, reducer and
// renderers fold a recorded turn (scenario fixture) from the in-page daemon. The
// default dark terminal theme is applied the way Swift applies it (theme.mjs).
// The screenshot is taken at the size of the reference's content area, then the
// scenario's compare rectangle of both is scored with pixelmatch, as
// codex-atlas-clone's scripts/compare-region.mjs does.
//
// References are not in this repository: pass --atlas or set CMUX_AGENT_PANE_ATLAS
// to a codex-atlas-clone checkout (default ~/Projects/codex-atlas-clone).
// Writes <out>/<scenario>/{ref,actual,diff,side}.png and prints the mismatch.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createServer } from "vite";
import { chromium } from "playwright";
import pixelmatch from "pixelmatch";
import { PNG } from "pngjs";
import { agentPaneTheme, ghosttyDefault } from "./theme.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const webviews = path.resolve(here, "../..");

/// Rectangles are CSS px. `pane` is the reference's main content area, where the
/// pane sits in the app; `compare` is the part scored, relative to `pane`.
/// `anchor` scrolls the transcript so the first line holding `text` has its top
/// `top` px below the pane's top, matching the reference's scroll position.
const scenarios = {
  "specimen-complete": {
    fixture: "specimen.json",
    reference: "reference/screenshots/chatgpt/specimen-complete.png",
    scale: 2,
    // The Outputs card floats over the right of the content area; the transcript
    // centers in what is left of it, so the pane ends where the card begins.
    pane: { x: 290.5, y: 44, width: 1122, height: 1036 },
    // Everything above the composer (cc-pane-composer owns the composer).
    compare: { x: 0, y: 0, width: 1122, height: 910 },
    anchor: { text: "UI Rendering Atlas Specimen", top: 166 },
  },
};

const args = process.argv.slice(2);
const option = (name) => {
  const index = args.indexOf(`--${name}`);
  if (index < 0) return undefined;
  const value = args[index + 1];
  if (value === undefined || value.startsWith("--")) throw new Error(`--${name} needs a value`);
  args.splice(index, 2);
  return value;
};
const atlas = path.resolve(option("atlas") ?? process.env.CMUX_AGENT_PANE_ATLAS ?? path.join(os.homedir(), "Projects/codex-atlas-clone"));
const outRoot = path.resolve(option("out") ?? path.join(os.tmpdir(), "cmux-agent-pane-compare"));
const names = args.length ? args : Object.keys(scenarios);
for (const name of names) if (!scenarios[name]) throw new Error(`unknown scenario ${name}; known: ${Object.keys(scenarios).join(", ")}`);

const server = await createServer({ configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"), server: { port: 0, strictPort: false }, logLevel: "error" });
await server.listen();
const url = server.resolvedUrls.local[0];
try {
  const browser = await chromium.launch();
  try {
    for (const name of names) console.log(await run(browser, name, scenarios[name]));
  } finally {
    await browser.close();
  }
} finally {
  await server.close();
}

async function run(browser, name, scenario) {
  const fixture = JSON.parse(fs.readFileSync(path.join(here, scenario.fixture), "utf8"));
  const referencePath = path.join(atlas, scenario.reference);
  if (!fs.existsSync(referencePath)) throw new Error(`${referencePath} not found; pass --atlas <codex-atlas-clone checkout>`);
  const reference = PNG.sync.read(fs.readFileSync(referencePath));
  const { pane, compare, scale } = scenario;

  const context = await browser.newContext({ viewport: { width: Math.round(pane.width), height: Math.round(pane.height) }, deviceScaleFactor: scale, colorScheme: "dark" });
  try {
    const page = await context.newPage();
    // A page that throws is not the pane being measured.
    const errors = [];
    page.on("pageerror", (error) => errors.push(error.message));
    await page.addInitScript(({ steps, endAtMs }) => {
      window.cmuxAcpmuxMockScript = { steps, endAtMs };
      window.cmuxAcpmuxActions = { ready: async () => ({ protocolVersion: 1, transport: "mock" }) };
    }, { steps: fixture.steps, endAtMs: fixture.endAtMs });
    await page.goto(url, { waitUntil: "networkidle" });
    // Swift applies the theme once the page has loaded.
    await page.waitForFunction(() => window.cmuxAcpmuxBridge && window.cmuxAcpmuxActions?.["chat.send"]);
    await page.evaluate((theme) => window.cmuxAcpmuxBridge.applyTheme(theme), agentPaneTheme(ghosttyDefault));
    // The mock daemon answers the prompt once the recorded turn has finished.
    await page.evaluate((prompt) => window.cmuxAcpmuxActions["chat.send"]({ text: prompt }), fixture.prompt);
    // The turn is drawn once its closing row is: wait for React to commit it.
    await page.waitForFunction(() => document.querySelector('.acpmux-scroll [data-row-id^="summary-"]'));
    await page.evaluate(() => document.fonts.ready);
    if (scenario.anchor) await scrollToAnchor(page, scenario.anchor);
    await settle(page);
    const shot = PNG.sync.read(await page.screenshot({ animations: "disabled", caret: "hide" }));
    if (errors.length) throw new Error(`${name}: the page threw: ${errors.join("; ")}`);

    const crop = (source, x, y) => {
      const [w, h] = [Math.round(compare.width * scale), Math.round(compare.height * scale)];
      const out = new PNG({ width: w, height: h });
      PNG.bitblt(source, out, Math.round(x * scale), Math.round(y * scale), w, h, 0, 0);
      return out;
    };
    const expected = crop(reference, pane.x + compare.x, pane.y + compare.y);
    const actual = crop(shot, compare.x, compare.y);
    const { width, height } = expected;
    const diff = new PNG({ width, height });
    const mismatched = pixelmatch(expected.data, actual.data, diff.data, width, height, { threshold: 0.1 });
    // At 0.1 two near-black backgrounds count as equal; the strict score shows color casts too.
    const strict = pixelmatch(expected.data, actual.data, null, width, height, { threshold: 0.02 });
    const side = new PNG({ width: width * 2, height });
    PNG.bitblt(expected, side, 0, 0, width, height, 0, 0);
    PNG.bitblt(actual, side, 0, 0, width, height, width, 0);
    const dir = path.join(outRoot, name);
    fs.mkdirSync(dir, { recursive: true });
    for (const [file, png] of Object.entries({ ref: expected, actual, diff, side })) fs.writeFileSync(path.join(dir, `${file}.png`), PNG.sync.write(png));
    const percent = (count) => (100 * count / (width * height)).toFixed(3);
    return `${name}: ${percent(mismatched)}% mismatched, ${percent(strict)}% at threshold 0.02 (${dir})`;
  } finally {
    await context.close();
  }
}

/// Scrolls the transcript until `anchor.text` starts `anchor.top` px below the top.
/// The transcript is virtualized, so rows below the fold mount only once scrolled to:
/// step down a viewport at a time until the text is mounted, then correct.
function settle(page) {
  return page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
}

async function scrollToAnchor(page, anchor) {
  for (let attempt = 0; attempt < 40; attempt++) {
    const delta = await page.evaluate(({ text, top }) => {
      const scroller = document.querySelector(".acpmux-scroll");
      if (!scroller) return "no transcript scroller (.acpmux-scroll)";
      const walker = document.createTreeWalker(scroller, NodeFilter.SHOW_TEXT);
      for (let node = walker.nextNode(); node; node = walker.nextNode()) {
        const at = node.data.indexOf(text);
        if (at < 0) continue;
        const range = document.createRange();
        range.setStart(node, at);
        range.setEnd(node, at + text.length);
        const delta = range.getBoundingClientRect().top - top;
        scroller.scrollTop += delta;
        return Math.abs(delta) < 0.5 ? 0 : delta;
      }
      const before = scroller.scrollTop;
      scroller.scrollTop += scroller.clientHeight;
      return scroller.scrollTop === before ? `anchor text not found in one text node: ${text}` : Infinity;
    }, anchor);
    if (typeof delta === "string") throw new Error(delta);
    await settle(page);
    if (delta === 0) return;
  }
  throw new Error(`could not settle the scroll on ${anchor.text}`);
}
