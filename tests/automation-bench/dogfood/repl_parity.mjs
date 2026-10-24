#!/usr/bin/env node
// Code mode parity run: the browser dogfood tasks (tasks.json) driven only
// through cmux code mode, the way an agent does it: `cmux mcp serve` over
// stdio, one `cmux_exec` script per task that calls `browser_repl_eval`.
//
//   node repl_parity.mjs [--cmux PATH] [--tasks FILE] [--only ID,ID]
//                        [--style cmux|aside|both] [--engine auto|headless|cef]
//                        [--polyfill] [--out results.jsonl]
//
// --style cmux writes each task with the cmux REPL names (tabs.open,
// snapshot(), page.close); --style aside writes the same task the way an
// `aside repl` script does (openTab, snapshot(page), listBrowserTabs,
// closeTab), so its pass rate shows whether Aside scripts run unchanged.
// --polyfill defines the Aside names in the script itself over tabs.* (the
// same thin wrappers as the host's aside-compat.js), to measure a host that
// predates them. One JSONL row per task and style, and a summary per style.
// Live sites are flaky: compare runs of the same day. No task signs in, pays
// or types a password. The default task list is 10 tasks from tasks.json.

import { spawn } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const DEFAULT_CMUX = "/Applications/cmux NIGHTLY.app/Contents/Resources/bin/cmux";
const DEFAULT_ONLY = [
  "example-title",
  "hn-story-links",
  "hn-click-new",
  "wikipedia-search",
  "httpbin-form",
  "internet-checkboxes",
  "internet-dropdown",
  "internet-dynamic-loading",
  "internet-iframe-snapshot",
  "todomvc-add",
];

function parseArgs(argv) {
  const args = { cmux: DEFAULT_CMUX, tasks: join(HERE, "tasks.json"), only: DEFAULT_ONLY, style: "both", engine: "auto", polyfill: false, out: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const next = () => argv[++i];
    if (a === "--cmux") args.cmux = next();
    else if (a === "--tasks") args.tasks = next();
    else if (a === "--only") args.only = next().split(",").filter(Boolean);
    else if (a === "--all") args.only = null;
    else if (a === "--style") args.style = next();
    else if (a === "--engine") args.engine = next();
    else if (a === "--polyfill") args.polyfill = true;
    else if (a === "--out") args.out = next();
    else throw new Error(`unknown argument ${a}`);
  }
  return args;
}

// A newline-delimited JSON-RPC client of `cmux mcp serve`.
class Mcp {
  constructor(cmux) {
    // An agent chat's env turns the server on without editing cmux.json.
    const env = { ...process.env, CMUX_AGENT_SESSION: process.env.CMUX_AGENT_SESSION || `repl-parity-${process.pid}` };
    this.child = spawn(cmux, ["mcp", "serve"], { stdio: ["pipe", "pipe", "inherit"], env });
    this.pending = new Map();
    this.next = 1;
    let buffer = "";
    this.child.stdout.on("data", (chunk) => {
      buffer += chunk;
      let nl;
      while ((nl = buffer.indexOf("\n")) >= 0) {
        const line = buffer.slice(0, nl).trim();
        buffer = buffer.slice(nl + 1);
        if (!line) continue;
        const message = JSON.parse(line);
        const waiter = this.pending.get(message.id);
        if (waiter) {
          this.pending.delete(message.id);
          waiter(message);
        }
      }
    });
  }
  request(method, params) {
    const id = this.next++;
    this.child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
    return new Promise((resolve) => this.pending.set(id, resolve));
  }
  notify(method, params) {
    this.child.stdin.write(JSON.stringify({ jsonrpc: "2.0", method, params }) + "\n");
  }
  async start() {
    const init = await this.request("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "repl-parity", version: "1" } });
    if (init.error) throw new Error(`initialize: ${JSON.stringify(init.error)}`);
    this.notify("notifications/initialized", {});
  }
  async exec(script) {
    const answer = await this.request("tools/call", { name: "cmux_exec", arguments: { script } });
    if (answer.error) return { failed: true, text: JSON.stringify(answer.error) };
    const result = answer.result || {};
    const text = (result.content || []).map((c) => c.text || "").join("\n");
    return { failed: !!result.isError, text, structured: result.structuredContent };
  }
  stop() {
    this.child.stdin.end();
  }
}

// The Aside names over tabs.*, for hosts that predate aside-compat.js.
const POLYFILL = `
if (typeof listBrowserTabs !== "function") {
  globalThis.listBrowserTabs = async () => (await tabs.list({ all: true })).map((t) => ({ targetId: t.id, title: t.title, url: t.url, active: t.active }));
  globalThis.openTab = (url) => tabs.open(url);
  globalThis.closeTab = async (tab) => { const p = tab || page; await p.close(); };
  globalThis.getTabByTargetId = (id) => tabs.get(id);
  globalThis.attachBrowserTab = (id) => tabs.use(id);
}
`;

const q = (value) => JSON.stringify(value);

// The script's answer ({ parity, error, tail }) inside a cmux_exec result.
function findParity(answer) {
  const seen = [];
  const walk = (value) => {
    if (typeof value === "string") {
      try {
        walk(JSON.parse(value));
      } catch {}
      return;
    }
    if (!value || typeof value !== "object") return;
    if ("parity" in value && "tail" in value) seen.push(value);
    for (const child of Object.values(value)) walk(child);
  };
  walk(answer.structured);
  walk(answer.text);
  return seen[0] || { parity: null, error: answer.failed ? answer.text : null, tail: answer.text };
}

// One task as REPL code for `style`. The code prints one JSON line {ok, detail}.
function taskCode(task, style, fixtureDir) {
  const aside = style === "aside";
  const lines = [];
  lines.push(aside ? `const p = await openTab(${q(task.url)});` : `const p = await tabs.open(${q(task.url)});`);
  lines.push(`p.on("dialog", (d) => d.accept().catch(() => {}));`);
  lines.push("let ok = true, detail = '';");
  lines.push("try {");
  for (const step of task.steps || []) {
    const [verb, ...rest] = step;
    const flag = (name) => {
      const i = rest.indexOf(name);
      return i >= 0 ? rest[i + 1] : undefined;
    };
    const timeout = Number(flag("--timeout-ms") || 15000);
    const first = (sel) => `p.locator(${q(sel)}).first()`;
    if (verb === "click") lines.push(`await ${first(rest[0])}.click();`);
    else if (verb === "fill") lines.push(`await ${first(rest[0])}.fill(${q(rest[1])});`);
    else if (verb === "check") lines.push(`await ${first(rest[0])}.check();`);
    else if (verb === "select") lines.push(`await ${first(rest[0])}.selectOption(${q(rest[1])});`);
    else if (verb === "hover") lines.push(`await ${first(rest[0])}.hover();`);
    else if (verb === "scroll-into-view") lines.push(`await ${first(rest[0])}.scrollIntoViewIfNeeded();`);
    else if (verb === "upload") lines.push(`await ${first(rest[0])}.setInputFiles(${q(rest[1].replace("{fixture}", fixtureDir))});`);
    else if (verb === "press") {
      const sel = flag("--selector");
      lines.push(sel ? `await ${first(sel)}.press(${q(rest[0])});` : `await p.keyboard.press(${q(rest[0])});`);
    } else if (verb === "wait") {
      if (flag("--url-contains") !== undefined) lines.push(`await p.waitForURL((u) => String(u).includes(${q(flag("--url-contains"))}), { timeout: ${timeout} });`);
      else if (flag("--text") !== undefined) lines.push(`await p.getByText(${q(flag("--text"))}).first().waitFor({ timeout: ${timeout} });`);
      else if (flag("--load-state") !== undefined) lines.push(`await p.waitForLoadState("load", { timeout: ${timeout} });`);
      else lines.push(`await ${first(rest[0])}.waitFor({ timeout: ${timeout} });`);
    } else lines.push(`throw new Error("unknown step ${verb}");`);
  }
  if (task.check) {
    lines.push(`if (!(await p.evaluate(${q(task.check)}))) { ok = false; detail += "check false: " + ${q(task.check.slice(0, 80))}; }`);
  }
  if (task.snapshot_check) {
    const sc = task.snapshot_check;
    lines.push(aside ? "const snap = await snapshot(p);" : "const snap = await snapshot(p, { maxChars: Infinity });");
    lines.push("const tree = String(snap.tree);");
    for (const text of sc.contains || []) lines.push(`if (!tree.includes(${q(text)})) { ok = false; detail += ${q(`missing ${text}; `)}; }`);
    if (sc.min_refs) lines.push(`{ const refs = (tree.match(/\\[ref=/g) || []).length; if (refs < ${sc.min_refs}) { ok = false; detail += "refs " + refs + "; "; } }`);
  }
  if (task.tabs_check) {
    lines.push(aside ? "const open = await listBrowserTabs();" : "const open = await tabs.list();");
    lines.push(`if (!open.some((t) => String(t.url).includes(${q(task.tabs_check.url_contains)}))) { ok = false; detail += "no tab with ${task.tabs_check.url_contains}"; }`);
  }
  lines.push("} catch (e) { ok = false; detail = String(e && e.message || e).slice(0, 300); }");
  lines.push(aside ? "await closeTab(p).catch(() => {});" : "await p.close().catch(() => {});");
  lines.push("console.log(JSON.stringify({ ok, detail }));");
  return lines.join("\n");
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const all = JSON.parse(readFileSync(args.tasks, "utf8")).tasks;
  const tasks = args.only ? args.only.map((id) => all.find((t) => t.id === id)).filter(Boolean) : all;
  const styles = args.style === "both" ? ["cmux", "aside"] : [args.style];
  const mcp = new Mcp(args.cmux);
  await mcp.start();
  const rows = [];
  for (const style of styles) {
    const session = `repl-parity-${style}-${process.pid}`;
    const open = await mcp.exec(`return await cmux.browser_repl_open(${q({ session, engine: args.engine })});`);
    const engine = /"engine"\s*:\s*"(\w+)"/.exec(open.text);
    console.error(`[${style}] session ${session}: ${open.failed ? "open failed: " + open.text.slice(0, 300) : "engine " + (engine ? engine[1] : "?")}`);
    for (const task of tasks) {
      let code = taskCode(task, style, dirname(args.tasks));
      if (args.polyfill && style === "aside") code = POLYFILL + code;
      const started = Date.now();
      const answer = await mcp.exec(
        `const r = await cmux.browser_repl_eval(${q({ session, code, timeoutMs: 60000 })});
         const out = String((r && r.output) || "");
         let parity = null;
         try { parity = JSON.parse(out.trim().split("\\n").pop()); } catch (e) {}
         return { parity, error: r && r.error, tail: out.slice(-300) };`,
      );
      const found = findParity(answer);
      const ok = !!(found.parity && found.parity.ok);
      const detail = found.parity ? found.parity.detail : String(found.error || found.tail || answer.text).slice(0, 400);
      const row = { task_id: task.id, style, engine: engine ? engine[1] : null, ok, detail, wall_ms: Date.now() - started };
      rows.push(row);
      console.error(`[${style}] ${ok ? "PASS" : "FAIL"} ${task.id}${ok ? "" : ": " + detail}`);
    }
    await mcp.exec(`return await cmux.browser_repl_close(${q({ session })});`);
  }
  mcp.stop();
  if (args.out) writeFileSync(args.out, rows.map((r) => JSON.stringify(r)).join("\n") + "\n");
  for (const style of styles) {
    const mine = rows.filter((r) => r.style === style);
    console.log(JSON.stringify({ style, engine: mine[0] && mine[0].engine, passed: mine.filter((r) => r.ok).length, total: mine.length }));
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
