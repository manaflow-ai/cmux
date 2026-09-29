#!/usr/bin/env node
// Browser REPL parity runner.
//
// Each scenario is REPL code in one dialect: `aside` (Aside's `aside repl`
// globals) or `chatgpt` (the ChatGPT for Chrome `agent` runtime). A reference
// backend records goldens; `cmux browser repl` must reproduce them.
//
//   node tests/browser-parity/run.mjs record --backend aside
//   node tests/browser-parity/run.mjs check  --backend cmux [--dialect aside] [--only 03]
//
// Backends: aside, chatgpt, playwright, cmux, cmux-dev. See tests/browser-parity/README.md.
import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { startFixtureServers } from "./lib/fixture-server.mjs";
import { normalize, diffEmits } from "./lib/normalize.mjs";
import { runPlaywright } from "./lib/playwright-backend.mjs";
import { expectedEmits } from "./lib/goldens.mjs";

const root = path.dirname(fileURLToPath(import.meta.url));
const MARK = "@@PARITY@@";

function parseArgs(argv) {
  const args = { mode: argv[0], backend: null, dialect: null, only: null, verbose: false };
  for (let i = 1; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--backend") args.backend = argv[++i];
    else if (a === "--dialect") args.dialect = argv[++i];
    else if (a === "--only") args.only = argv[++i];
    else if (a === "-v" || a === "--verbose") args.verbose = true;
    else throw new Error(`unknown argument ${a}`);
  }
  if (args.mode === "ax") return args;
  if (!["record", "check", "run"].includes(args.mode) || !args.backend) {
    throw new Error("usage: run.mjs record|check|run --backend aside|chatgpt|playwright|cmux|cmux-dev [--dialect aside|chatgpt] [--only PREFIX]\n       run.mjs ax [--only PREFIX] [-v]");
  }
  return args;
}

// The reference backend for each dialect. `record` only accepts these.
const referenceFor = { aside: ["aside", "playwright"], chatgpt: ["chatgpt"] };

// `emitFile` routes values through a file for backends whose stdout is not the
// REPL's own output (the ChatGPT runtime runs behind a Codex model turn).
function prelude(origins, emitFile) {
  const line = `${JSON.stringify(MARK)} + JSON.stringify({ k, v: v === undefined ? null : v })`;
  return [
    `const PRIMARY = ${JSON.stringify(origins.primary)};`,
    `const PEER = ${JSON.stringify(origins.peer)};`,
    emitFile
      ? `const __emitFs = await import("node:fs"); const emit = (k, v) => __emitFs.appendFileSync(${JSON.stringify(emitFile)}, ${line} + "\\n");`
      : `const emit = (k, v) => console.log(${line});`,
  ].join("\n");
}

function wrap(origins, body, emitFile) {
  return `${prelude(origins, emitFile)}\ntry {\n${body}\n} catch (__e) { emit("__error__", String(__e && __e.message || __e).split("\\n")[0]); }\n`;
}

function run(cmd, argv, { input, timeoutMs = 180_000, env } = {}) {
  return new Promise((resolve) => {
    const child = spawn(cmd, argv, { stdio: ["pipe", "pipe", "pipe"], env: { ...process.env, ...env } });
    let out = "";
    let err = "";
    const timer = setTimeout(() => child.kill("SIGKILL"), timeoutMs);
    child.stdout.on("data", (d) => (out += d));
    child.stderr.on("data", (d) => (err += d));
    child.on("close", (code) => {
      clearTimeout(timer);
      resolve({ code, out, err });
    });
    if (input != null) child.stdin.end(input);
    else child.stdin.end();
  });
}

function parseEmits(stdout) {
  const emits = [];
  for (const line of stdout.split("\n")) {
    const i = line.indexOf(MARK);
    if (i < 0) continue;
    try {
      emits.push(JSON.parse(line.slice(i + MARK.length).replace(/\u001b\[[0-9;]*m/g, "")));
    } catch {
      emits.push({ k: "__unparsed__", v: line });
    }
  }
  return emits;
}

const backends = {
  // Aside Browser through its CLI. One-shot sessions close their tabs on exit.
  async aside(code) {
    const r = await run("aside", ["repl", code]);
    return { emits: parseEmits(r.out), raw: r.out + r.err };
  },
  // The ChatGPT for Chrome runtime inside Codex's privileged node_repl. It
  // needs a Codex login that uses a ChatGPT account (not an API key); set
  // PARITY_CHATGPT_CODEX_HOME to that CODEX_HOME.
  async chatgpt(_code, { scenarioName, origins, body }) {
    const client = path.join(
      process.env.HOME,
      ".codex/plugins/cache/openai-bundled/chrome/latest/scripts/browser-client.mjs",
    );
    const work = fs.mkdtempSync("/private/tmp/parity-chatgpt-");
    const modPath = path.join(work, `${scenarioName}.mjs`);
    const emitFile = path.join(work, "emits.jsonl");
    fs.writeFileSync(modPath, `export async function run(agent) {\n${wrap(origins, body, emitFile)}\n}\n`);
    const prompt = [
      "Use the MCP server named node_repl (tool js). Run exactly this code in one call and nothing else:",
      `const { setupBrowserRuntime } = await import(${JSON.stringify(client)});`,
      "globalThis.agent ??= await setupBrowserRuntime({});",
      `await (await import(${JSON.stringify("file://" + modPath)})).run(agent);`,
      "Then reply with the exact tool output verbatim.",
    ].join("\n");
    const env = process.env.PARITY_CHATGPT_CODEX_HOME ? { CODEX_HOME: process.env.PARITY_CHATGPT_CODEX_HOME } : {};
    const r = await run("codex", ["exec", "--skip-git-repo-check", "-s", "danger-full-access", prompt], { env, timeoutMs: 400_000 });
    const emitted = fs.existsSync(emitFile) ? fs.readFileSync(emitFile, "utf8") : "";
    return { emits: parseEmits(emitted), raw: r.out + r.err };
  },
  // Real Playwright on headless Chrome with Aside's globals shimmed. It is the
  // tie-breaker where Aside deviates from Playwright semantics.
  async playwright(code) {
    try {
      const out = await runPlaywright(code);
      return { emits: parseEmits(out), raw: out };
    } catch (e) {
      return { emits: [], raw: String(e.stack || e) };
    }
  },
  // The engine-neutral runtime (Resources/browser-repl) in this process on
  // Playwright WebKit through the `dev` driver. No app build needed.
  async "cmux-dev"(code) {
    const { runDevRepl } = await import("./lib/dev-driver.mjs");
    try {
      const out = await runDevRepl(code);
      return { emits: parseEmits(out), raw: out };
    } catch (e) {
      return { emits: [], raw: String(e.stack || e) };
    }
  },
  // cmux's own REPL. PARITY_CMUX_CLI selects a tagged build's CLI and
  // CMUX_SOCKET_PATH its socket.
  async cmux(code, { dialect }) {
    const cli = process.env.PARITY_CMUX_CLI ?? "cmux";
    const r = await run(cli, ["browser", "repl", "--dialect", dialect, "--eval", "-"], { input: code });
    return { emits: parseEmits(r.out), raw: r.out + r.err };
  },
};

// Compares cmux-dev's tab.ax text with ChatGPT's own renderer
// (lib/chatgpt-ax-reference.mjs on headless Chrome) for every fixture page and
// for the action sequence of scenarios/chatgpt/02-ax-actions.js.
async function axCheck(args) {
  // Playwright reads the browsers path when it loads; the dev driver's WebKit
  // lives in the parity cache.
  process.env.PLAYWRIGHT_BROWSERS_PATH ??= path.join(process.env.HOME, ".cache/cmux-parity-browsers");
  const { loadChatGPTAccessibilityCore, ChatGPTAxReference, loadPlaywright } = await import("./lib/chatgpt-ax-reference.mjs");
  const { runDevRepl } = await import("./lib/dev-driver.mjs");
  const server = await startFixtureServers();
  const core = await loadChatGPTAccessibilityCore();
  const { chromium } = loadPlaywright();
  const browser = await chromium.launch({ channel: "chrome", headless: true });
  const urlFor = (p) => `${server.origins.primary}${p}?peer=${encodeURIComponent(server.origins.peer)}`;
  // Reference: one Chrome tab per case; `steps` run between captures.
  const reference = async (pagePath, steps) => {
    const context = await browser.newContext({ viewport: { width: 1280, height: 800 } });
    const page = await context.newPage();
    const ref = new ChatGPTAxReference(page, core, { tabId: 1 });
    await page.goto(urlFor(pagePath), { waitUntil: "load" });
    await page.waitForTimeout(150);
    let dialog = null;
    page.on("dialog", (d) => (dialog = d));
    const out = [await ref.state({ disableDiffing: true })];
    for (const step of steps) {
      await step(page);
      await page.waitForTimeout(250);
      if (dialog) {
        out.push(await ref.dialogState(dialog, { disableDiffing: false }));
        await dialog.dismiss().catch(() => {});
        dialog = null;
      } else out.push(await ref.state({ disableDiffing: false }));
    }
    await context.close();
    return out;
  };
  const cmux = async (pagePath, steps) => {
    const code = [
      "const b = await agent.browsers.getDefault(); const tab = await b.tabs.new();",
      `await tab.goto(${JSON.stringify(urlFor(pagePath))});`,
      `const s1 = await tab.ax.get("state", { disableDiffing: true }); console.log(${JSON.stringify(MARK)} + JSON.stringify(s1));`,
      "const idx = (re) => Number(s1.split('\\n').find((l) => re.test(l)).trim().split(' ')[0]);",
      ...steps.map((s) => `${s} await new Promise((r) => setTimeout(r, 250)); console.log(${JSON.stringify(MARK)} + JSON.stringify(await tab.ax.get()));`),
    ].join("\n");
    const out = await runDevRepl(code);
    return out.split("\n").filter((l) => l.includes(MARK)).map((l) => JSON.parse(l.slice(l.indexOf(MARK) + MARK.length)));
  };
  const pages = fs.readdirSync(path.join(root, "fixtures")).filter((f) => f.endsWith(".html") && f !== "frame-inner.html").sort();
  const cases = pages.map((f) => ({ name: f, page: `/${f}`, ref: [], mine: [] }));
  cases.push({
    name: "02-ax-actions",
    page: "/index.html",
    ref: [
      async (p) => {
        await p.fill("#email", "me@x.com");
        await p.click("#tos");
        await p.click("#submit");
      },
      async (p) => {
        await p.focus("#bio");
        await p.evaluate(() => { const b = document.getElementById("bio"); b.setSelectionRange(b.value.length, b.value.length); });
        await p.keyboard.type(" there");
        await p.keyboard.press("Tab");
        await p.locator("#far").evaluate((e) => e.scrollIntoView({ block: "center" }));
      },
    ],
    mine: [
      "await tab.ax.setValue(idx(/textbox Email|text field.*Email/), 'me@x.com'); await tab.ax.click(idx(/checkbox.*Accept terms/)); await tab.ax.click(idx(/button Create account/));",
      "await tab.ax.typeText(idx(/Bio/), ' there'); await tab.ax.pressKey(null, 'Tab'); await tab.ax.scroll(idx(/button Far away/), 'down', 1);",
    ],
  });
  // Revision diffs and the no-change message need pages above the renderer's
  // 1000-byte saving threshold, so these use the ARIA fixture.
  cases.push({
    name: "aria-diff",
    page: "/aria.html",
    ref: [
      async () => {},
      async (p) => {
        await p.evaluate(() => {
          document.querySelector("h1").textContent = "Changed heading";
          document.querySelector("details").open = true;
          document.querySelector("footer").insertAdjacentHTML("beforebegin", "<button>Added</button>");
        });
      },
      async (p) => {
        await p.evaluate(() => document.querySelector("nav").remove());
      },
    ],
    mine: [
      "",
      "await tab.playwright.evaluate(() => { document.querySelector('h1').textContent = 'Changed heading'; document.querySelector('details').open = true; document.querySelector('footer').insertAdjacentHTML('beforebegin', '<button>Added</button>'); });",
      "await tab.playwright.evaluate(() => document.querySelector('nav').remove());",
    ],
  });
  cases.push({
    name: "aria-focus",
    page: "/aria.html",
    ref: [async (p) => p.focus("input[title]")],
    mine: ["await tab.playwright.locator('input[title]').focus();"],
  });
  cases.push({
    name: "dialog-prompt",
    page: "/dialogs.html",
    ref: [(p) => { p.click("#prompt", { noWaitAfter: true }).catch(() => {}); }, async () => {}],
    mine: [
      "tab.playwright.locator('#prompt').click().catch(() => {}); for (let i = 0; i < 50 && !(await tab.getJsDialog()); i++) await new Promise((r) => setTimeout(r, 50));",
      "await (await tab.getJsDialog()).dismiss();",
    ],
  });
  let failures = 0;
  let ran = 0;
  try {
    for (const c of cases) {
      if (args.only && !c.name.startsWith(args.only)) continue;
      ran++;
      const expected = (await reference(c.page, c.ref)).map((t) => normalize(t, server.origins));
      const actual = (await cmux(c.page, c.mine)).map((t) => normalize(t, server.origins));
      const problems = diffEmits(expected.map((v, i) => ({ k: `capture ${i}`, v })), actual.map((v, i) => ({ k: `capture ${i}`, v })));
      if (problems.length) {
        failures++;
        console.log(`FAIL ax/${c.name}`);
        for (const p of problems) console.log(`  ${p}`);
        if (args.verbose) console.log(`--- expected\n${expected.join("\n=====\n")}\n--- actual\n${actual.join("\n=====\n")}`);
      } else {
        console.log(`PASS ax/${c.name}`);
        if (args.verbose) console.log(actual.join("\n=====\n"));
      }
    }
  } finally {
    await browser.close();
    await server.close();
  }
  console.log(`\n${ran - failures}/${ran} AX cases match`);
  process.exitCode = failures ? 1 : 0;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.mode === "ax") return axCheck(args);
  const run = backends[args.backend];
  if (!run) throw new Error(`unknown backend ${args.backend}`);
  const dialects = args.dialect ? [args.dialect] : Object.keys(referenceFor);
  const server = await startFixtureServers();
  let failures = 0;
  let total = 0;
  try {
    for (const dialect of dialects) {
      if (args.mode === "record" && !referenceFor[dialect].includes(args.backend)) continue;
      const dir = path.join(root, "scenarios", dialect);
      const files = fs.readdirSync(dir).filter((f) => f.endsWith(".js") && (!args.only || f.startsWith(args.only))).sort();
      for (const file of files) {
        const scenarioName = file.replace(/\.js$/, "");
        const body = fs.readFileSync(path.join(dir, file), "utf8");
        const result = await run(wrap(server.origins, body), { dialect, scenarioName, origins: server.origins, body });
        const emits = result.emits.map((e) => ({ k: e.k, v: normalize(e.v, server.origins) }));
        const goldenDir = path.join(root, "goldens", dialect);
        const goldenPath = path.join(goldenDir, `${scenarioName}${args.backend === "playwright" ? ".playwright" : ""}.json`);
        total++;
        // `run` prints values without comparing, for scenarios that have no
        // golden yet.
        if (args.mode === "run") {
          console.log(`${dialect}/${scenarioName}`);
          for (const e of emits) console.log(`  ${e.k} = ${JSON.stringify(e.v).slice(0, 240)}`);
          if (args.verbose || !emits.length) console.log(result.raw.slice(-3000));
          continue;
        }
        if (args.mode === "record") {
          fs.mkdirSync(path.dirname(goldenPath), { recursive: true });
          fs.writeFileSync(goldenPath, JSON.stringify(emits, null, 2) + "\n");
          const errors = emits.filter((e) => e.k === "__error__");
          console.log(`recorded ${dialect}/${scenarioName}: ${emits.length} values${errors.length ? ` (reference error: ${errors[0].v})` : ""}`);
          if (!emits.length) console.log(result.raw.slice(-2000));
          continue;
        }
        const golden = expectedEmits(goldenDir, scenarioName);
        if (!golden) {
          console.log(`SKIP ${dialect}/${scenarioName}: no golden`);
          continue;
        }
        const problems = diffEmits(golden, emits);
        if (problems.length) {
          failures++;
          console.log(`FAIL ${dialect}/${scenarioName}`);
          for (const p of problems) console.log(`  ${p}`);
          if (args.verbose || !emits.length) console.log(result.raw.slice(-3000));
        } else {
          console.log(`PASS ${dialect}/${scenarioName}`);
        }
      }
    }
  } finally {
    await server.close();
  }
  if (args.mode === "check") {
    console.log(`\n${total - failures}/${total} scenarios match`);
    process.exitCode = failures ? 1 : 0;
  }
}

main().catch((e) => {
  console.error(e.message);
  process.exitCode = 2;
});
