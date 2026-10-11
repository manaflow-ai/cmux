#!/usr/bin/env node
// Passkey regression runner (plans/cmux-next/passkeys.md, sections 5 and 7).
//
// Serves the local test RP (tests/passkeys/rp) on http://localhost:<port>
// (frame.localhost is the cross-origin iframe origin; Chromium resolves
// *.localhost to loopback and treats it as a secure context), then runs every
// scenario in Chromium with a DevTools virtual authenticator, so no Touch ID,
// phone or security key is involved. Stock Chromium is the oracle: a scenario
// that passes there must pass in a cmux CEF pane, and fails if cmux repeats a
// bug from the passkeys.md "Known bugs" table.
//
//   node tests/passkeys/run.mjs                       # stock Chromium (Playwright's)
//   node tests/passkeys/run.mjs --executable <chrome> # another Chromium build
//   node tests/passkeys/run.mjs --cdp http://127.0.0.1:<port>  # an existing browser, e.g. a cmux CEF test instance
//   node tests/passkeys/run.mjs --only get-large-challenge --json out.json
//   node tests/passkeys/run.mjs --serve [--port 8765]  # serve only, for manual runs in a cmux pane
//
// Exit 0 when every judged scenario passes, 1 otherwise. Record-only
// scenarios (pass null) print NOTE and never fail the run.
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const rpDir = path.join(here, "rp");
const require = createRequire(import.meta.url);

function parseArgs(argv) {
  const args = { only: [], port: 0 };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const next = () => argv[++i];
    if (a === "--executable") args.executable = next();
    else if (a === "--cdp") args.cdp = next();
    else if (a === "--only") args.only.push(next());
    else if (a === "--json") args.json = next();
    else if (a === "--serve") args.serve = true;
    else if (a === "--port") args.port = Number(next());
    else if (a === "--headed") args.headed = true;
    else throw new Error(`unknown argument: ${a}`);
  }
  return args;
}

const TYPES = { ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8" };

export function serve(port = 0) {
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, "http://localhost");
    const name = url.pathname === "/" ? "index.html" : path.basename(url.pathname);
    const file = path.join(rpDir, name);
    if (!fs.existsSync(file)) {
      res.writeHead(404).end("not found");
      return;
    }
    res.writeHead(200, { "content-type": TYPES[path.extname(file)] || "application/octet-stream", "cache-control": "no-store" });
    fs.createReadStream(file).pipe(res);
  });
  return new Promise((resolve) => server.listen(port, "127.0.0.1", () => resolve(server)));
}

function loadPlaywright() {
  const dirs = [process.env.PARITY_PLAYWRIGHT_DIR].filter(Boolean);
  for (const d of dirs) {
    try {
      return require(path.join(d, "playwright"));
    } catch {}
  }
  return require("playwright");
}

// Newest Chromium that Playwright installed, unless one is given.
function defaultExecutable() {
  if (process.env.PASSKEY_CHROMIUM) return process.env.PASSKEY_CHROMIUM;
  const cache = process.env.PLAYWRIGHT_BROWSERS_PATH || path.join(os.homedir(), "Library/Caches/ms-playwright");
  if (!fs.existsSync(cache)) return undefined;
  const dirs = fs.readdirSync(cache).filter((d) => /^chromium-\d+$/.test(d)).sort((a, b) => Number(b.split("-")[1]) - Number(a.split("-")[1]));
  for (const d of dirs) {
    for (const arch of ["chrome-mac-arm64", "chrome-mac", "chrome-linux"]) {
      const app = path.join(cache, d, arch, "Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing");
      if (fs.existsSync(app)) return app;
      const linux = path.join(cache, d, arch, "chrome");
      if (fs.existsSync(linux)) return linux;
    }
  }
  return undefined;
}

const SCENARIO_TIMEOUT_MS = 30000;

function withTimeout(promise, ms, name) {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(`${name} did not settle in ${ms} ms`)), ms);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

async function runScenario(page, name, spec) {
  const cdp = await page.context().newCDPSession(page);
  await cdp.send("WebAuthn.enable", { enableUI: false });
  const { authenticatorId } = await cdp.send("WebAuthn.addVirtualAuthenticator", {
    options: { automaticPresenceSimulation: true, ...spec.authenticator },
  });
  try {
    const pending = withTimeout(page.evaluate((n) => window.runPasskeyScenario(n), name), SCENARIO_TIMEOUT_MS, name);
    if (spec.frame && spec.frame.click) {
      await page.frameLocator(`iframe[data-scenario="${name}"]`).locator(spec.frame.click).click({ timeout: 10000 });
    }
    return await pending;
  } finally {
    await cdp.send("WebAuthn.removeVirtualAuthenticator", { authenticatorId }).catch(() => {});
    await cdp.send("WebAuthn.disable").catch(() => {});
    await cdp.detach().catch(() => {});
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const server = await serve(args.port);
  const port = server.address().port;
  const base = `http://localhost:${port}/`;
  if (args.serve) {
    console.log(`passkey test RP: ${base}`);
    return;
  }
  const { chromium } = loadPlaywright();
  const browser = args.cdp
    ? await chromium.connectOverCDP(args.cdp)
    : await chromium.launch({ executablePath: args.executable || defaultExecutable(), headless: !args.headed });
  const context = args.cdp ? browser.contexts()[0] : await browser.newContext();
  const page = await context.newPage();
  const results = [];
  let failed = 0;
  try {
    await page.goto(base);
    const browserVersion = browser.version();
    const specs = await page.evaluate(() =>
      Object.fromEntries(Object.entries(window.PASSKEY_SCENARIOS).map(([k, v]) => [k, { authenticator: v.authenticator, frame: v.frame }])));
    for (const [name, spec] of Object.entries(specs)) {
      if (args.only.length && !args.only.includes(name)) continue;
      const r = await runScenario(page, name, spec).catch(async (e) => {
        await page.goto(base); // a stuck scenario must not poison the next one
        return { name, pass: false, detail: `runner: ${e.message.split("\n")[0]}` };
      });
      results.push(r);
      const tag = r.pass === true ? "PASS" : r.pass === false ? "FAIL" : "NOTE";
      if (r.pass === false) failed++;
      console.log(`${tag} ${name}: ${r.detail}`);
    }
    if (args.json) fs.writeFileSync(args.json, JSON.stringify({ browser: browserVersion, results }, null, 2) + "\n");
    console.log(`${results.length - failed}/${results.length} ok on ${browserVersion}`);
  } finally {
    await page.close().catch(() => {});
    if (!args.cdp) await browser.close();
    server.close();
  }
  process.exitCode = failed ? 1 : 0;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  main().catch((e) => {
    console.error(e);
    process.exitCode = 1;
  });
}
