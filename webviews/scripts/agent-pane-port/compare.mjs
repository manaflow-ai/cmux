#!/usr/bin/env node
// Screenshot-by-screenshot comparison of both agent pane prototypes against the ChatGPT
// reference captures in codex-atlas-clone:
//
//   node scripts/agent-pane-port/compare.mjs --atlas <codex-atlas-clone> [--out DIR] [scenario ...]
//
// For each scenario both panes run from their dev configs in headless Chromium with the
// host bridge stubbed to mock mode, replay the same reference thread through the real
// acpmux client (the mock daemon, fed by rollout-to-script.ts from the clone's rollouts),
// get the same cmux default theme Swift applies, perform the same clicks, and are captured
// at the reference's size less the icon rail (cmux owns window chrome). Writes
// <out>/<scenario>/{reference,current,port}.png and <out>/index.html, a three-column
// gallery. Nothing from the private clone is committed: fixtures are converted at run time.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { createServer } from "vite";
import { chromium } from "playwright";
import { PNG } from "pngjs";
import { agentPaneTheme, ghosttyDefault } from "../agent-pane/theme.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const webviews = path.resolve(here, "../..");
const args = process.argv.slice(2);
const option = (name, fallback) => {
  const index = args.indexOf(`--${name}`);
  if (index < 0) return fallback;
  const value = args[index + 1];
  args.splice(index, 2);
  return value;
};
const atlas = path.resolve(
  option("atlas", process.env.CMUX_AGENT_PANE_ATLAS ?? path.join(os.homedir(), "Projects/codex-atlas-clone")),
);
const outRoot = path.resolve(option("out", path.join(os.tmpdir(), "cmux-agent-pane-port-compare")));
const RAIL = 52;

/// Actions: ["click", text] clicks the innermost control whose text starts with `text`
/// (the last match with `last`); ["chip", "mode"|"model"] opens a composer picker;
/// ["scroll", "top"|"bottom"|text]; ["changes"] opens the Changes view the pane's own way
/// (View changes on the newest edited-files card, else the title toggle);
/// ["press", selector by pane].
const S = (reference, fixture, actions = [], extra = {}) => ({ reference, fixture, actions, ...extra });
const scenarios = {
  home: S("home.png", null, [["click", "New chat"]]),
  "new-chat": S("new-chat.png", null, [["click", "New chat"]]),
  overview: S("overview.png", "sota", [
    ["click", "Worked for"],
    ["click", "Searched the web"],
    ["scroll", "top"],
  ]),
  "live-sota-worked-collapsed": S("live/live-sota-worked-collapsed.png", "sota", [["scroll", "top"]]),
  "live-sota-worked-expanded": S("live/live-sota-worked-expanded.png", "sota", [
    ["click", "Worked for"],
    ["scroll", "top"],
  ]),
  "live-sota-search-expanded": S("live/live-sota-search-expanded.png", "sota", [
    ["click", "Worked for"],
    ["click", "Searched the web"],
    ["scroll", "top"],
  ]),
  "specimen-complete": S("specimen-complete.png", "specimen", [["scroll", "UI Rendering Atlas Specimen"]]),
  "live-devapps-top": S("live/live-devapps-top.png", "devapps", [["scroll", "top"]]),
  "live-devapps-last-turn": S("live/live-devapps-last-turn.png", "devapps", [["scroll", "bottom"]]),
  "live-devapps-worked-expanded": S("live/live-devapps-worked-expanded.png", "devapps", [
    ["click", "Worked for", "last"],
    ["scroll", "bottom"],
  ]),
  "live-devapps-ran-commands-expanded": S(
    "live/live-devapps-ran-commands-expanded.png",
    "devapps",
    [
      ["click", "Worked for", "last"],
      ["scroll", "bottom"],
    ],
    { note: "the fold is open; the group this capture opens is left closed" },
  ),
  "live-getappstate-bottom": S("live/live-getappstate-bottom.png", "getappstate", [["scroll", "bottom"]]),
  "live-getappstate-worked-expanded": S("live/live-getappstate-worked-expanded.png", "getappstate", [
    ["click", "Worked for", "last"],
    ["scroll", "bottom"],
  ]),
  "live-freestyle-bottom": S("live/live-freestyle-bottom.png", "freestyle", [["scroll", "bottom"]]),
  "live-freestyle-edit-group-expanded": S(
    "live/live-freestyle-edit-group-expanded.png",
    "freestyle",
    [
      ["click", "Worked for", "last"],
      ["scroll", "bottom"],
    ],
    { note: "the fold is open; the edit group is left closed" },
  ),
  "live-topology-bottom": S("live/live-topology-bottom.png", "topology", [["scroll", "bottom"]]),
  "permissions-menu": S("permissions-menu.png", null, [["chip", "mode"]], {
    note: "seeded mock workspace: a recorded script's session has no modes",
  }),
  "model-menu": S("model-menu.png", null, [["chip", "model"]]),
  "manual-view-changes": S("manual-view-changes.png", "freestyle", [["scroll", "bottom"], ["changes"]]),
  "manual-changes-current": S("manual-changes-current.png", "freestyle", [["changes"]]),
  "changes-branch-menu": S("changes-branch-menu.png", "freestyle", [["changes"], ["click", "Last Turn"]]),
  "changes-options": S("changes-options.png", "freestyle", [
    ["changes"],
    ["press", { port: '[aria-label="Changes options"]' }],
  ]),
  search: S("search.png", "sota", [["press", { key: "Meta+k" }]]),
  "chat-sidebar-menu": S("chat-sidebar-menu.png", null, [["press", { rightClickRow: true }]]),
  "fixture-trust-dialog": S("fixture-trust-dialog.png", null, [["click", "New chat"]]),
  "specimen-streaming": S("specimen-streaming.png", "specimen", [["scroll", "bottom"]], {
    note: "the mock cannot hold a turn open; both show the finished turn",
  }),
};

const panes = {
  current: {
    config: "vite.config.acpmux-pane.mjs",
    scroller: ".acpmux-scroll",
    mode: ".acpmux-mode button, .acpmux-mode",
    model: ".acpmux-model button, .acpmux-model",
  },
  port: {
    config: "vite.config.acpmux-port.mjs",
    scroller: ".cv-thread__viewport",
    mode: ".cx-permission",
    model: ".cx-model",
  },
};

const names = args.length ? args : Object.keys(scenarios);
const fixtureCache = new Map();
function fixture(name) {
  if (!fixtureCache.has(name)) {
    const rollout = path.join(atlas, "src/conversation/fixtures/rollouts", `${name}.jsonl`);
    const json = execFileSync("bun", [path.join(here, "rollout-to-script.ts"), rollout], {
      cwd: webviews,
      maxBuffer: 1 << 28,
    });
    fixtureCache.set(name, JSON.parse(json.toString()));
  }
  return fixtureCache.get(name);
}

const servers = {};
for (const [name, pane] of Object.entries(panes)) {
  // Separate optimizer caches: two servers sharing one re-optimize and reload each other.
  const server = await createServer({
    configFile: path.join(webviews, pane.config),
    cacheDir: path.join(webviews, "node_modules", `.vite-compare-${name}`),
    server: { port: 0, strictPort: false },
    logLevel: "error",
  });
  await server.listen();
  servers[name] = server;
  pane.url = server.resolvedUrls.local[0];
}
const browser = await chromium.launch();
const results = [];
try {
  for (const name of names) {
    const scenario = scenarios[name];
    if (!scenario) throw new Error(`unknown scenario ${name}`);
    const referencePath = path.join(atlas, "reference/screenshots/chatgpt", scenario.reference);
    const reference = PNG.sync.read(fs.readFileSync(referencePath));
    const width = Math.round(reference.width / 2) - RAIL;
    const height = Math.round(reference.height / 2);
    const dir = path.join(outRoot, name);
    fs.mkdirSync(dir, { recursive: true });
    fs.copyFileSync(referencePath, path.join(dir, "reference.png"));
    const row = { name, reference: scenario.reference, note: scenario.note, errors: {} };
    for (const [paneName, pane] of Object.entries(panes)) {
      try {
        await capture(pane, scenario, width, height, path.join(dir, `${paneName}.png`));
      } catch (error) {
        row.errors[paneName] = String(error.message ?? error).split("\n")[0];
      }
    }
    results.push(row);
    console.log(`${name}: ${Object.keys(row.errors).length ? JSON.stringify(row.errors) : "ok"}`);
  }
} finally {
  await browser.close();
  for (const server of Object.values(servers)) await server.close();
}
fs.writeFileSync(path.join(outRoot, "index.html"), gallery(results));
fs.writeFileSync(path.join(outRoot, "results.json"), JSON.stringify(results, null, 2));
console.log(`gallery: ${path.join(outRoot, "index.html")}`);

async function capture(pane, scenario, width, height, out) {
  const context = await browser.newContext({ viewport: { width, height }, deviceScaleFactor: 2, colorScheme: "dark" });
  try {
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", (error) => errors.push(error.message));
    await page.addInitScript((scripted) => {
      // One script object the mock daemon reads at each prompt; the harness swaps its turn.
      if (scripted) window.cmuxAcpmuxMockScript = { steps: [], endAtMs: 0 };
      window.cmuxAcpmuxActions = { ready: async () => ({ protocolVersion: 1, transport: "mock" }) };
    }, Boolean(scenario.fixture));
    await page.goto(pane.url, { waitUntil: "networkidle" });
    await page.waitForFunction(() => window.cmuxAcpmuxBridge && window.cmuxAcpmuxActions?.["chat.send"], null, {
      timeout: 15000,
    });
    await page.evaluate((theme) => window.cmuxAcpmuxBridge.applyTheme(theme), agentPaneTheme(ghosttyDefault));
    if (scenario.fixture) {
      // The mock stamps a turn's events at its start plus the recorded offsets; move the
      // page clock past each turn's end so the next turn starts after it, as it did live.
      let now = Date.now() - 3 * 864e5;
      for (const turn of fixture(scenario.fixture)) {
        await page.clock.setSystemTime(now);
        now += turn.endAtMs + 120_000;
        await page.evaluate(async (turn) => {
          window.cmuxAcpmuxMockScript.steps = turn.steps;
          window.cmuxAcpmuxMockScript.endAtMs = turn.endAtMs;
          await window.cmuxAcpmuxActions["chat.send"]({ text: turn.prompt });
        }, turn);
      }
    }
    await page.evaluate(() => document.fonts.ready);
    await settle(page, 400);
    for (const action of scenario.actions) await act(page, pane, action);
    await settle(page, 600);
    await page.screenshot({ path: out, animations: "disabled", caret: "hide" });
    if (errors.length) throw new Error(`page threw: ${errors.join("; ")}`);
  } finally {
    await context.close();
  }
}

async function act(page, pane, [kind, value, which]) {
  if (kind === "click") {
    const ok = await page.evaluate(
      ({ text, last }) => {
        const candidates = [
          ...document.querySelectorAll("button, [role=button], [role=menuitem], a, .cv-worked, .cv-tool, .cv-group"),
        ].filter((el) => {
          const label = (el.textContent ?? "").trim();
          return label.startsWith(text) && el.getClientRects().length > 0;
        });
        // Innermost: drop candidates that contain another candidate.
        const inner = candidates.filter((el) => !candidates.some((other) => other !== el && el.contains(other)));
        const target = last ? inner.at(-1) : inner[0];
        target?.scrollIntoView({ block: "center" });
        target?.click();
        return Boolean(target);
      },
      { text: value, last: which === "last" },
    );
    if (!ok) throw new Error(`no control "${value}"`);
  } else if (kind === "chip") {
    const selector = pane[value];
    const handle = await page.$(selector);
    if (!handle) throw new Error(`no ${value} chip (${selector})`);
    await handle.click();
  } else if (kind === "scroll") {
    await page.evaluate(
      ({ selector, to }) => {
        const scroller = document.querySelector(selector);
        if (!scroller) return;
        // A user gesture first: a pinned transcript re-applies its end position until one.
        scroller.dispatchEvent(new WheelEvent("wheel", { bubbles: true, deltaY: -1 }));
        if (to === "top") scroller.scrollTop = 0;
        else if (to === "bottom") scroller.scrollTop = scroller.scrollHeight;
        else {
          const walker = document.createTreeWalker(scroller, NodeFilter.SHOW_TEXT);
          for (let node = walker.nextNode(); node; node = walker.nextNode()) {
            if (!node.data.includes(to)) continue;
            node.parentElement.scrollIntoView({ block: "start" });
            scroller.scrollTop -= 120;
            return;
          }
        }
      },
      { selector: pane.scroller, to: value },
    );
    // Virtualized transcripts mount rows after a scroll; settle twice.
    await settle(page, 300);
  } else if (kind === "changes") {
    const opened = await page.evaluate(() => {
      const view = [...document.querySelectorAll("button, [role=button], span")]
        .filter((el) => (el.textContent ?? "").trim() === "View changes")
        .at(-1);
      if (view) {
        view.click();
        return true;
      }
      const toggle = document.querySelector('[aria-label="Toggle changes"]');
      toggle?.click();
      return Boolean(toggle);
    });
    if (!opened) throw new Error("no way to open Changes");
  } else if (kind === "press") {
    if (value.key) await page.keyboard.press(value.key);
    else if (value.rightClickRow) {
      const row = await page.$(".cx-row--indent, .acpmux-session-row, [data-session-id]");
      if (!row) throw new Error("no session row");
      await row.click({ button: "right" });
    } else {
      const selector = value[pane === panes.port ? "port" : "current"];
      if (!selector) throw new Error("no such control in this pane");
      const handle = await page.$(selector);
      if (!handle) throw new Error(`no ${selector}`);
      await handle.click();
    }
  }
  await settle(page, 250);
}

function settle(page, ms) {
  return page.evaluate(
    (ms) => new Promise((resolve) => setTimeout(() => requestAnimationFrame(() => requestAnimationFrame(resolve)), ms)),
    ms,
  );
}

function gallery(rows) {
  const cell = (row, file, label) => {
    const error = row.errors[file];
    return `<figure><figcaption>${label}${error ? ` <em>${escape(error)}</em>` : ""}</figcaption>${error && !fs.existsSync(path.join(outRoot, row.name, `${file}.png`)) ? "<div class=missing>not captured</div>" : `<a href="${row.name}/${file}.png"><img loading=lazy src="${row.name}/${file}.png"></a>`}</figure>`;
  };
  return `<!doctype html><meta charset=utf-8><title>Agent pane prototypes vs reference</title>
<style>body{margin:0;padding:16px;background:#1e1e1c;color:#ddd;font:13px system-ui}h2{font-size:14px;margin:28px 0 8px}section{display:grid;grid-template-columns:repeat(3,1fr);gap:10px}figure{margin:0}figcaption{color:#999;margin-bottom:4px}em{color:#d98}img{width:100%;border-radius:6px;background:#000}.missing{aspect-ratio:16/10;display:grid;place-items:center;background:#2a2a28;border-radius:6px;color:#777}p{color:#999;margin:2px 0}</style>
<h1>Agent pane: reference, current (agent-session), port (agent-session-port)</h1>
${rows.map((row) => `<h2 id="${row.name}">${row.name} <small>(${row.reference})</small></h2>${row.note ? `<p>${escape(row.note)}</p>` : ""}<section>${cell(row, "reference", "ChatGPT reference")}${cell(row, "current", "Current pane")}${cell(row, "port", "Port prototype")}</section>`).join("\n")}`;
}

function escape(text) {
  return String(text).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
}
