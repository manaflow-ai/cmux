// One adapter per engine. Every adapter runs the same step list on one page:
//   { op: "capture", mode: "full" | "interactive" }
//   { op: "eval", js }            an expression evaluated in the page
//   { op: "resolve", from, names } resolve refs read from capture `from`
// and returns one result per step. A capture result maps tool id to
// { text, incremental? }; `incremental` is what the tool prints after a
// change when it has a diff or incremental mode.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn, execFileSync } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";
import { createDevBrowser, createNodeHost, loadRuntime, loadPlaywright } from "../lib/dev-driver.mjs";
import { installSource, collectGroundTruth } from "./ground-truth.mjs";
import { VisibleDom, simplifyDomSnapshot } from "./chatgpt-formats.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, "../../..");
const MARK = "@@CMP@@";
// A desktop Chrome user agent so live sites serve the page a person gets;
// headless Chrome otherwise announces itself as HeadlessChrome.
export const DESKTOP_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36";
export const VIEWPORT = { width: 1280, height: 800 };

function withTimeout(p, ms, what) {
  let timer;
  const t = new Promise((_, rej) => (timer = setTimeout(() => rej(new Error(`${what} timed out after ${ms}ms`)), ms)));
  return Promise.race([p, t]).finally(() => clearTimeout(timer));
}

// Program text shared by the two REPL tools (cmux and Aside), which both
// print `[ref=…]` refs and resolve them with page.locator(ref).
function replProgram(steps, { snapshotCall, open, close, settleMs, wait }) {
  const body = [];
  steps.forEach((s) => {
    if (s.op === "capture") {
      body.push(`{ const __s = await ${snapshotCall(s.mode === "interactive")}; __out.push({ text: __s.tree, incremental: __s.diff ?? null, printed: String(__s) }); }`);
    } else if (s.op === "eval") {
      body.push(`await page.evaluate(${JSON.stringify(s.js)}); await ${wait}(250); __out.push(null);`);
    } else if (s.op === "act") {
      // Real input through the tool's own locators, as an agent acts.
      const steps = s.actions.map((a) => (a.fill ? `await page.locator(${JSON.stringify(a.fill)}).fill(${JSON.stringify(a.value)});` : `await page.locator(${JSON.stringify(a.click)}).click();`));
      body.push(`${steps.join(" ")} await ${wait}(300); __out.push(null);`);
    } else if (s.op === "resolve") {
      body.push(`{ const __txt = __out[${s.from}].text; const __r = {};
  for (const __n of ${JSON.stringify(s.names)}) {
    const __line = __txt.split("\\n").find((l) => l.includes(JSON.stringify(__n)) && /\\[ref=/.test(l));
    const __ref = __line ? __line.match(/\\[ref=([^\\]]+)\\]/)[1] : null;
    if (!__ref) { __r[__n] = { ref: null }; continue; }
    try { __r[__n] = { ref: __ref, text: await page.locator(__ref).textContent({ timeout: 1500 }) }; }
    catch (e) { __r[__n] = { ref: __ref, error: String(e && e.message || e).split("\\n")[0].slice(0, 200) }; }
  }
  __out.push({ resolve: __r }); }`);
    }
  });
  return `const __out = [];
${open}
try {
  await ${wait}(${settleMs});
  ${body.join("\n  ")}
} catch (e) { __out.push({ error: String(e && e.message || e) }); } finally { ${close} }
console.log(${JSON.stringify(MARK)} + JSON.stringify(__out));`;
}

function parseMarked(text) {
  const line = text.split("\n").find((l) => l.includes(MARK));
  if (!line) throw new Error(`no result marker in output: ${text.slice(-600)}`);
  const out = JSON.parse(line.slice(line.indexOf(MARK) + MARK.length));
  const failed = out.find((x) => x && x.error && !("text" in x));
  if (failed) throw new Error(failed.error);
  return out;
}

// cmux: the Resources/browser-repl runtime in this process on Playwright
// WebKit through the dev driver (the `cmux-dev` backend of run.mjs).
export async function createCmuxAdapter() {
  const ns = loadRuntime();
  const browser = await createDevBrowser({ viewport: VIEWPORT });
  const workDir = fs.mkdtempSync(path.join(os.tmpdir(), "cmp-cmux-"));
  return {
    name: "cmux",
    async run(url, steps, { settleMs }) {
      const lines = [];
      const driver = browser.driver();
      const host = createNodeHost({ workDir, sessionId: `cmp-${Date.now()}`, print: (_l, t) => lines.push(t) });
      const repl = ns.replHost.createBrowserRepl({ host, driver });
      const code = replProgram(steps, {
        snapshotCall: (i) => (i ? "snapshot({ interactive: true })" : "snapshot()"),
        open: `await page.goto(${JSON.stringify(url)});`,
        close: "",
        settleMs,
        wait: "page.waitForTimeout",
      });
      try {
        const r = await withTimeout(repl.evaluate(code), 150_000, "cmux");
        if (!r.ok) throw new Error(String(r.error));
        const out = parseMarked(lines.join("\n"));
        return steps.map((s, i) => (s.op === "capture" ? { [s.mode === "interactive" ? "cmux-i" : "cmux"]: out[i] } : out[i] && { cmux: out[i] }));
      } finally {
        repl.dispose();
        await driver.detach().catch(() => {});
      }
    },
    close: async () => {
      await browser.close();
      fs.rmSync(workDir, { recursive: true, force: true });
    },
  };
}

// Aside: one `aside repl` one-shot call per page (never `aside exec`). It
// opens its own tab in Aside Browser and closes it.
export function createAsideAdapter() {
  return {
    name: "aside",
    async run(url, steps, { settleMs }) {
      const code = replProgram(steps, {
        snapshotCall: (i) => (i ? "snapshot(page, { interactive: true })" : "snapshot(page)"),
        open: `const __tab = await openTab(${JSON.stringify(url)});`,
        close: "await closeTab(__tab).catch(() => {});",
        settleMs,
        wait: "sleep",
      });
      const { out, err, code: exit } = await run("aside", ["repl", code], { timeoutMs: 150_000 });
      if (exit !== 0 && !out.includes(MARK)) throw new Error(`aside repl exit ${exit}: ${(err || out).slice(-400)}`);
      const res = parseMarked(out);
      return steps.map((s, i) => (s.op === "capture" ? { [s.mode === "interactive" ? "aside-i" : "aside"]: res[i] } : res[i] && { aside: res[i] }));
    },
    close: async () => {},
  };
}

function run(cmd, argv, { input, timeoutMs = 120_000, cwd } = {}) {
  return new Promise((resolve) => {
    const child = spawn(cmd, argv, { stdio: ["pipe", "pipe", "pipe"], cwd });
    let out = "";
    let err = "";
    const timer = setTimeout(() => child.kill("SIGKILL"), timeoutMs);
    child.stdout.on("data", (d) => (out += d));
    child.stderr.on("data", (d) => (err += d));
    child.on("close", (code) => {
      clearTimeout(timer);
      resolve({ code, out, err });
    });
    child.stdin.end(input ?? "");
  });
}

// The ChatGPT for Chrome reference renderer. It was removed from lib/ with the
// dialects; the comparison loads it from git history, pinned.
const CHATGPT_REF_COMMIT = "2e4c54b6fa8";
function chatgptReferencePath() {
  const dest = path.join(here, "results/.cache/chatgpt-ax-reference.mjs");
  if (!fs.existsSync(dest)) {
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    const src = execFileSync("git", ["-C", repoRoot, "show", `${CHATGPT_REF_COMMIT}:tests/browser-parity/lib/chatgpt-ax-reference.mjs`], { maxBuffer: 1 << 24 });
    fs.writeFileSync(dest, src);
  }
  return dest;
}

// Headless Google Chrome, one throwaway context per page. ChatGPT's AX text,
// the two reproduced ChatGPT formats, Playwright MCP's AI snapshot and the
// ground truth all read the same page.
export async function createChromeAdapter() {
  const { loadChatGPTAccessibilityCore, ChatGPTAxReference } = await import(chatgptReferencePath());
  const core = await loadChatGPTAccessibilityCore();
  const { chromium } = loadPlaywright();
  const browser = await chromium.launch({ channel: "chrome", headless: true });
  return {
    name: "chrome",
    async run(url, steps, { settleMs }) {
      const context = await browser.newContext({ viewport: VIEWPORT, userAgent: DESKTOP_UA });
      await context.addInitScript(installSource);
      const page = await context.newPage();
      page.on("dialog", (d) => d.dismiss().catch(() => {}));
      const ax = new ChatGPTAxReference(page, core, { tabId: 1 });
      const vdom = new VisibleDom(page);
      const results = [];
      let groundTruth = null;
      try {
        await page.goto(url, { waitUntil: "load", timeout: 60_000 }).catch((e) => {
          if (!/timeout/i.test(e.message)) throw e;
        });
        await page.waitForTimeout(settleMs);
        for (const s of steps) {
          if (s.op === "eval") {
            await page.evaluate(s.js);
            await page.waitForTimeout(250);
            results.push(null);
          } else if (s.op === "act") {
            for (const a of s.actions) {
              if (a.fill) await page.fill(a.fill, a.value);
              else await page.click(a.click);
            }
            await page.waitForTimeout(300);
            results.push(null);
          } else if (s.op === "resolve") {
            const txt = results[s.from]["pw-mcp"].raw;
            const r = {};
            for (const n of s.names) {
              const line = txt.split("\n").find((l) => l.includes(JSON.stringify(n)) && /\[ref=/.test(l));
              const ref = line ? line.match(/\[ref=([^\]]+)\]/)[1] : null;
              if (!ref) r[n] = { ref: null };
              else r[n] = await page.locator(`aria-ref=${ref}`).textContent({ timeout: 1500 }).then((text) => ({ ref, text }), (e) => ({ ref, error: e.message.split("\n")[0].slice(0, 200) }));
            }
            results.push({ "pw-mcp": { resolve: r } });
          } else if (s.op === "capture") {
            if (s.mode === "interactive") {
              results.push({});
              continue;
            }
            if (!groundTruth) {
              groundTruth = await collectGroundTruth(page);
              if (groundTruth.frames[0]?.error) throw new Error(`ground truth failed in the main frame: ${groundTruth.frames[0].error}`);
            }
            const cap = {};
            const time = async (fn) => {
              const t0 = Date.now();
              const v = await fn();
              return [v, Date.now() - t0];
            };
            try {
              const [inc, ms] = await time(() => ax.state());
              const full = await ax.state({ disableDiffing: true });
              cap["chatgpt-ax"] = { text: full, incremental: inc, ms };
            } catch (e) {
              cap["chatgpt-ax"] = { error: String(e.message || e) };
            }
            try {
              const [text, ms] = await time(() => vdom.get());
              cap["chatgpt-dom"] = { text, ms };
            } catch (e) {
              cap["chatgpt-dom"] = { error: String(e.message || e) };
            }
            try {
              const [snap, ms] = await time(() => page._snapshotForAI({ track: "cmp" }));
              const title = await page.title();
              const wrap = (y) => `### Page state\n- Page URL: ${page.url()}\n- Page Title: ${title}\n- Page Snapshot:\n\`\`\`yaml\n${y}\n\`\`\``;
              cap["pw-mcp"] = { text: wrap(snap.full), incremental: snap.incremental != null ? wrap(snap.incremental) : null, raw: snap.full, ms };
              cap["chatgpt-pw"] = { text: simplifyDomSnapshot((await page._snapshotForAI()).full) };
            } catch (e) {
              cap["pw-mcp"] = { error: String(e.message || e) };
            }
            results.push(cap);
          }
        }
        return { results, groundTruth, finalUrl: page.url(), title: await page.title().catch(() => null) };
      } finally {
        await context.close().catch(() => {});
      }
    },
    close: () => browser.close(),
  };
}

// browser-use 0.13 in an isolated venv (see setup.sh), headless Chrome with a
// throwaway profile. Its selector-map indices are the addresses.
export function createBrowserUseAdapter() {
  const python = process.env.CMP_BU_PYTHON ?? path.join(here, ".venv/bin/python");
  return {
    name: "browser-use",
    available: fs.existsSync(python),
    async run(url, steps, { settleMs }) {
      const job = { url, settle: settleMs / 1000, steps: steps.map((s) => (s.op === "capture" ? { kind: "capture", mode: s.mode } : s.op === "eval" ? { kind: "eval", js: s.js } : { kind: "noop" })) };
      // cwd "/" keeps stray Python files in the shell's directory off sys.path.
      const r = await run(python, [path.join(here, "browser_use_capture.py")], { input: JSON.stringify(job), timeoutMs: 180_000, cwd: "/" });
      if (r.code !== 0) throw new Error(`browser-use exit ${r.code}: ${r.err.split("\n").filter((l) => /Error|Traceback/.test(l)).slice(-3).join(" | ") || r.err.slice(-300)}`);
      const res = JSON.parse(r.out.trim().split("\n").pop());
      return { version: res.version, results: steps.map((s, i) => (s.op === "capture" && s.mode !== "interactive" ? { "browser-use": res.results[i] } : null)) };
    },
    close: async () => {},
  };
}

// Stagehand 4 `page.snapshot({ includeIframes: true }).formattedTree`, with
// its Chrome extension, on headless Chrome for Testing (branded Chrome no
// longer loads unpacked extensions).
export async function createStagehandAdapter() {
  let mod;
  let entry;
  try {
    entry = fileURLToPath(import.meta.resolve("@browserbasehq/stagehand"));
    mod = await import(pathToFileURL(entry).href);
  } catch {
    return { name: "stagehand", available: false };
  }
  const exe = process.env.CMP_CHROME_FOR_TESTING ?? findChromeForTesting();
  if (!exe) return { name: "stagehand", available: false };
  const version = JSON.parse(fs.readFileSync(path.join(path.dirname(entry), "../package.json"), "utf8")).version;
  return {
    name: "stagehand",
    available: true,
    version,
    async run(url, steps, { settleMs }) {
      const profile = fs.mkdtempSync(path.join(os.tmpdir(), "cmp-sh-"));
      const browser = await mod.localBrowser.launch({ headless: true, executablePath: exe, viewport: VIEWPORT, userDataDir: profile, args: [`--user-agent=${DESKTOP_UA}`] });
      let sh;
      try {
        sh = await mod.Stagehand.create({ browser, logging: { level: "error" } });
        const ctx = sh.context ?? sh.browser?.context;
        const page = (await ctx.pages())[0] ?? (await ctx.newPage());
        await withTimeout(page.goto(url), 60_000, "stagehand goto").catch((e) => {
          if (!/timed out|timeout/i.test(e.message)) throw e;
        });
        await page.waitForTimeout(settleMs);
        const out = [];
        for (const s of steps) {
          if (s.op === "eval") {
            await page.evaluate(s.js);
            await page.waitForTimeout(250);
            out.push(null);
          } else if (s.op === "capture" && s.mode !== "interactive") {
            const snap = await withTimeout(page.snapshot({ includeIframes: true }), 90_000, "stagehand snapshot");
            out.push({ stagehand: { text: snap.formattedTree } });
          } else out.push(null);
        }
        return out;
      } finally {
        await sh?.close?.().catch(() => {});
        await browser.close?.().catch(() => {});
        fs.rmSync(profile, { recursive: true, force: true });
      }
    },
    close: async () => {},
  };
}

function findChromeForTesting() {
  const base = path.join(os.homedir(), "Library/Caches/ms-playwright");
  if (!fs.existsSync(base)) return null;
  for (const d of fs.readdirSync(base).filter((d) => /^chromium-\d+$/.test(d)).sort().reverse()) {
    const exe = path.join(base, d, "chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing");
    if (fs.existsSync(exe)) return exe;
  }
  return null;
}
