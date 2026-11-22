#!/usr/bin/env node
// Renders the agent pane in mock mode and scores it against a native capture.
//
//   node scripts/agent-pane/compare.mjs [scenario ...] [--reference DIR] [--out DIR]
//     [--theme NAME] [--anchor TEXT] [--open]
//
// The pane runs from the dev server config (vite.config.acpmux-pane.mjs) with the
// host bridge stubbed: `ready` answers mock, so the production client, reducer and
// renderers fold a recorded turn (scenario fixture) from the in-page daemon. The
// default dark terminal theme is applied the way Swift applies it (theme.mjs).
// The screenshot is taken at the size of the reference's content area, then the
// scenario's compare rectangle of both is scored with pixelmatch, as
// the reference prototype's compare-region script does.
//
// References are not in this repository: pass --reference or set
// CMUX_AGENT_PANE_REFERENCE to a checkout of the private reference prototype.
// Writes <out>/<scenario>/{ref,actual,diff,side}.png and prints the mismatch.
//
// For captures rather than scores: --theme renders under a Ghostty theme from
// Resources/ghostty/themes (e.g. "Catppuccin Mocha"), --anchor scrolls to other text,
// and --open opens the turn's "Worked for" fold. The mismatch then means little.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createServer } from "vite";
import { chromium } from "playwright";
import pixelmatch from "pixelmatch";
import { PNG } from "pngjs";
import { agentPaneTheme, ghosttyDefault, ghosttyThemeFile } from "./theme.mjs";

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
  // A capture, not a score: a coding turn with every transcript part (the "Worked for"
  // fold, tool rows with output, edits, a code block and the edited-files card), for
  // showcase shots. Run it with --open --theme "Catppuccin Mocha".
  "worked-turn": {
    fixture: "worked-turn.json",
    scale: 2,
    pane: { x: 0, y: 0, width: 1200, height: 1000 },
    anchor: { text: "The reconnect test fails about one run in five", top: 72 },
  },
  // A capture: a turn that fetched pages, ran subagents, edited files, opened and merged pull
  // requests and scheduled wakeups, with the header's summary popover open over it.
  summary: {
    fixture: "summary-turn.json",
    scale: 2,
    pane: { x: 0, y: 0, width: 1200, height: 800 },
    open: ".acpmux-summary-button",
  },
  // The mock daemon's seeded workspace as it opens (mockFixture.ts): the populated sidebar
  // and its worked session, with no recorded script or prompt. A whole-window capture.
  workspace: {
    scale: 2,
    pane: { x: 0, y: 0, width: 1440, height: 900 },
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
const referenceOption = option("reference") ?? process.env.CMUX_AGENT_PANE_REFERENCE;
if (!referenceOption) {
  throw new Error("set --reference or CMUX_AGENT_PANE_REFERENCE to the reference prototype checkout");
}
const referenceRoot = path.resolve(referenceOption);
const outRoot = path.resolve(option("out") ?? path.join(os.tmpdir(), "cmux-agent-pane-compare"));
const themeName = option("theme");
const themeFile = themeName && path.resolve(webviews, "../Resources/ghostty/themes", themeName);
if (themeFile && !fs.existsSync(themeFile)) throw new Error(`no Ghostty theme ${themeFile}`);
const terminalTheme = themeFile ? ghosttyThemeFile(themeFile) : ghosttyDefault;
const anchorText = option("anchor");
const openFold = args.includes("--open");
if (openFold) args.splice(args.indexOf("--open"), 1);
const names = args.length ? args : Object.keys(scenarios);
for (const name of names)
  if (!scenarios[name]) throw new Error(`unknown scenario ${name}; known: ${Object.keys(scenarios).join(", ")}`);

const server = await createServer({
  configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
  server: { port: 0, strictPort: false },
  logLevel: "error",
});
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
  const fixture = scenario.fixture ? JSON.parse(fs.readFileSync(path.join(here, scenario.fixture), "utf8")) : undefined;
  const referencePath = scenario.reference && path.join(referenceRoot, scenario.reference);
  if (referencePath && !fs.existsSync(referencePath))
    throw new Error(`${referencePath} not found; pass --reference <reference checkout>`);
  const { pane, compare, scale } = scenario;

  const context = await browser.newContext({
    viewport: { width: Math.round(pane.width), height: Math.round(pane.height) },
    deviceScaleFactor: scale,
    colorScheme: "dark",
  });
  try {
    const page = await context.newPage();
    // A page that throws is not the pane being measured.
    const errors = [];
    page.on("pageerror", (error) => errors.push(error.message));
    await page.addInitScript(
      (script) => {
        if (script) window.cmuxAcpmuxMockScript = script;
        window.cmuxAcpmuxActions = {
          ready: async () => ({ protocolVersion: 1, transport: "mock" }),
        };
      },
      fixture && { steps: fixture.steps, endAtMs: fixture.endAtMs },
    );
    await page.goto(url, { waitUntil: "networkidle" });
    // Swift applies the theme once the page has loaded.
    await page.waitForFunction(() => window.cmuxAcpmuxBridge && window.cmuxAcpmuxActions?.["chat.send"]);
    await page.evaluate((theme) => window.cmuxAcpmuxBridge.applyTheme(theme), agentPaneTheme(terminalTheme));
    // The mock daemon answers the prompt once the recorded turn has finished; without a
    // fixture the seeded workspace already holds a finished turn.
    if (fixture)
      await page.evaluate((prompt) => window.cmuxAcpmuxActions["chat.send"]({ text: prompt }), fixture.prompt);
    // The turn is drawn once its closing row is: wait for React to commit it.
    await page.waitForFunction(() => document.querySelector('.acpmux-scroll [data-row-id^="summary-"]'));
    await page.evaluate(() => document.fonts.ready);
    if (openFold) {
      await page.click(".cv-worked");
      await page.waitForFunction(() => document.querySelector('.cv-worked[aria-expanded="true"]'));
      await settle(page);
    }
    // A scenario without its own anchor (workspace) scrolls `--anchor` text to the top of the pane.
    const anchor = anchorText ? { top: 0, ...scenario.anchor, text: anchorText } : scenario.anchor;
    if (anchor) await scrollToAnchor(page, { ...anchor, edge: !referencePath || Boolean(anchorText) });
    if (scenario.open) {
      await page.click(scenario.open);
      await page.waitForSelector(`${scenario.open}[aria-expanded="true"]`);
    }
    await settle(page);
    const shot = PNG.sync.read(await page.screenshot({ animations: "disabled", caret: "hide" }));
    if (errors.length) throw new Error(`${name}: the page threw: ${errors.join("; ")}`);
    const dir = path.join(outRoot, name);
    fs.mkdirSync(dir, { recursive: true });
    if (!referencePath) {
      fs.writeFileSync(path.join(dir, "actual.png"), PNG.sync.write(shot));
      return `${name}: captured (${path.join(dir, "actual.png")})`;
    }
    const reference = PNG.sync.read(fs.readFileSync(referencePath));

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
    const mismatched = pixelmatch(expected.data, actual.data, diff.data, width, height, {
      threshold: 0.1,
    });
    // At 0.1 two near-black backgrounds count as equal; the strict score shows color casts too.
    const strict = pixelmatch(expected.data, actual.data, null, width, height, { threshold: 0.02 });
    const side = new PNG({ width: width * 2, height });
    PNG.bitblt(expected, side, 0, 0, width, height, 0, 0);
    PNG.bitblt(actual, side, 0, 0, width, height, width, 0);
    for (const [file, png] of Object.entries({ ref: expected, actual, diff, side }))
      fs.writeFileSync(path.join(dir, `${file}.png`), PNG.sync.write(png));
    const percent = (count) => ((100 * count) / (width * height)).toFixed(3);
    return `${name}: ${percent(mismatched)}% mismatched, ${percent(strict)}% at threshold 0.02 (${dir})`;
  } finally {
    await context.close();
  }
}

function settle(page) {
  return page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
}

/// Scrolls the transcript until `anchor.text` starts `anchor.top` px below the top.
/// The transcript is virtualized, so rows below the fold mount only once scrolled to:
/// step down a viewport at a time until the text is mounted, then correct. Scroll offsets
/// snap to device pixels, so half a CSS pixel off is as close as it gets.
async function scrollToAnchor(page, anchor) {
  for (let attempt = 0; attempt < 40; attempt++) {
    const delta = await page.evaluate(
      ({ text, top, edge }) => {
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
          const from = scroller.scrollTop;
          scroller.scrollTop += delta;
          // A capture's text near either end can't reach `top`: the scroll stops at the edge.
          // A scored scenario must reach it, or the crop would be misaligned.
          const clamped = edge && Math.abs(delta) > 0.5 && Math.abs(scroller.scrollTop - from) < 0.5;
          return Math.abs(delta) <= 0.5 || clamped ? 0 : delta;
        }
        const before = scroller.scrollTop;
        scroller.scrollTop += scroller.clientHeight;
        return scroller.scrollTop === before ? `anchor text not found in one text node: ${text}` : Infinity;
      },
      { ...anchor, edge: Boolean(anchor.edge) },
    );
    if (typeof delta === "string") throw new Error(delta);
    await settle(page);
    if (delta === 0) return;
  }
  throw new Error(`could not settle the scroll on ${anchor.text}`);
}
