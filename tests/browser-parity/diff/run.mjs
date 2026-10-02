#!/usr/bin/env node
// Differential harness: one task, three dialects (cmux, Aside, ChatGPT for
// Chrome), observable outcomes compared into a verdict per reference.
// See tests/browser-parity/README.md, "Differential cases".
//
//   node tests/browser-parity/diff/run.mjs run --backend cmux-dev|cmux|aside|chatgpt [--only TEXT]
//   node tests/browser-parity/diff/run.mjs check --backend cmux-dev|cmux [--only TEXT]
//   node tests/browser-parity/diff/run.mjs verdicts [--only TEXT] [-v]
//   node tests/browser-parity/diff/run.mjs report
//
// run records outcomes into results/<backend>.json (merging into what is
// there); verdicts recomputes every verdict from those files.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { startDiffServer } from "./server.mjs";
import { MARK, REFERENCES, loadCases, dialectSource, expand, prelude, readResults, writeResults, allVerdicts, normalizeStrings } from "./lib.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const CASE_TIMEOUT_MS = Number(process.env.DIFF_CASE_TIMEOUT_MS ?? 150_000);

function parseArgs(argv) {
  const a = { mode: argv[0], backend: null, only: null, verbose: false, jobs: 1 };
  for (let i = 1; i < argv.length; i++) {
    if (argv[i] === "--backend") a.backend = argv[++i];
    else if (argv[i] === "--only") a.only = argv[++i];
    else if (argv[i] === "--jobs") a.jobs = Number(argv[++i]);
    else if (argv[i] === "--ids") a.ids = new Set(argv[++i].split(","));
    else if (argv[i] === "-v") a.verbose = true;
    else throw new Error(`unknown argument ${argv[i]}`);
  }
  return a;
}

export function exec(cmd, argv, { input, timeoutMs = 200_000, env } = {}) {
  return new Promise((resolve) => {
    const child = spawn(cmd, argv, { stdio: ["pipe", "pipe", "pipe"], env: env ?? process.env });
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

export function parseMarked(text) {
  const at = text.lastIndexOf(MARK);
  if (at < 0) return null;
  const line = text.slice(at + MARK.length).split("\n")[0];
  try {
    return JSON.parse(line);
  } catch {
    return { uncaught: `unparsable result: ${line.slice(0, 200)}` };
  }
}

// The same wrapper for every REPL dialect: navigate, run the body, print
// the outcome after the marker.
export function wrap(c, dialect, origins) {
  const body = expand(dialectSource(c, dialect), dialect);
  const nav = c.path == null ? "" : dialect === "aside" ? `await openTab(U(${JSON.stringify(c.path)}));` : `await page.goto(U(${JSON.stringify(c.path)}));`;
  const cleanup = dialect === "aside" ? "for (const __t of [...(tabs || [])]) { try { await closeTab(__t); } catch {} }" : "";
  return `${prelude(origins)}
const __r = await (async () => { ${nav}
${body}
})().then((v) => ({ value: v === undefined ? null : v }), (e) => ({ uncaught: String((e && e.message) || e).slice(0, 800) }));
${cleanup}
console.log(${JSON.stringify(MARK)} + JSON.stringify(__r));`;
}

// ---------------------------------------------------------------------------
// Backends

function cmuxCli() {
  return process.env.PARITY_CMUX_CLI ?? "cmux";
}

async function cmuxRepl(code, { session } = {}) {
  const argv = ["browser", "repl"];
  if (session) argv.push("--session", session);
  argv.push("--eval", "-");
  const r = await exec(cmuxCli(), argv, { input: code });
  return parseMarked(r.out) ?? { uncaught: `no result (exit ${r.code}): ${(r.err || r.out).trim().split("\n").slice(-3).join(" ").slice(0, 400)}` };
}

// Dev backend: one Playwright WebKit browser, REPL sessions on it the way
// the app keeps them, so custom cases can run two sessions at once.
async function devBackend() {
  const dev = await import("../lib/dev-driver.mjs");
  const ns = dev.loadRuntime();
  const workDir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "brepl-diff-")));
  const browser = await dev.createDevBrowser();
  const readable = new Set();
  const sessions = new Map();
  function open(name) {
    const driver = browser.driver();
    driver.on("download.finished", (p) => p.path && readable.add(fs.realpathSync(p.path)));
    let lines = [];
    const host = dev.createNodeHost({ workDir, sessionId: name, print: (l, t) => lines.push(t), readable });
    const repl = dev.createHostedRepl(ns, { host, driver }).repl;
    return { driver, repl, take: () => ((lines = []), undefined), text: () => lines.join("\n") };
  }
  async function repl(code, { session } = {}) {
    let s = session ? sessions.get(session) : null;
    if (!s) {
      s = open(session || `oneshot-${Math.random().toString(36).slice(2, 8)}`);
      if (session) sessions.set(session, s);
    }
    s.take();
    const r = await s.repl.evaluate(code);
    const text = s.text();
    if (!session) {
      s.repl.dispose();
      await s.driver.detach();
    }
    return parseMarked(text) ?? { uncaught: r.ok ? `no result: ${text.slice(-300)}` : String(r.error).slice(0, 600) };
  }
  return {
    repl,
    browser,
    async reset(session) {
      const s = sessions.get(session);
      if (!s) return;
      sessions.delete(session);
      s.repl.dispose();
      await s.driver.detach();
    },
    async close() {
      for (const name of [...sessions.keys()]) await this.reset(name);
      await browser.close();
      fs.rmSync(workDir, { recursive: true, force: true });
    },
  };
}

async function runReplBackend(backend, cases, origins, server, onResult) {
  const out = {};
  const dev = backend === "cmux-dev" ? await devBackend() : null;
  const suffix = Math.random().toString(36).slice(2, 7);
  const sessions = new Set();
  const repl = async (code, opts = {}) => {
    if (opts.session) sessions.add(opts.session);
    return dev ? dev.repl(code, opts) : cmuxRepl(code, opts);
  };
  const ctx = {
    origins,
    server,
    backend,
    dialect: "cmux",
    wrap: (c) => wrap(c, "cmux", origins),
    repl,
    session: (name) => `diff-${name}-${suffix}`,
    cli: (argv, input) => exec(cmuxCli(), argv, { input }),
    dev,
  };
  try {
    for (const c of cases) {
      const t0 = Date.now();
      let r;
      try {
        if (c.custom) {
          const fn = c.custom[backend] ?? c.custom.cmux;
          let timer;
          r = fn
            ? await Promise.race([
                fn(ctx).then((value) => ({ value })),
                new Promise((resolve) => (timer = setTimeout(() => resolve({ uncaught: `case did not finish in ${CASE_TIMEOUT_MS} ms` }), CASE_TIMEOUT_MS))),
              ])
            : { uncaught: `no ${backend} runner` };
          clearTimeout(timer);
        } else {
          // A case that never settles (a lost event, a held dialog) must not
          // stop the run; the call is abandoned and reported.
          let timer;
          r = await Promise.race([
            repl(wrap(c, backend, origins), c.session ? { session: ctx.session(c.session) } : {}),
            new Promise((resolve) => (timer = setTimeout(() => resolve({ uncaught: `case did not finish in ${CASE_TIMEOUT_MS} ms` }), CASE_TIMEOUT_MS))),
          ]);
          clearTimeout(timer);
        }
      } catch (e) {
        r = { uncaught: String(e.stack || e).slice(0, 800) };
      }
      out[c.id] = { ...r, ms: Date.now() - t0 };
      log(backend, c, out[c.id]);
      onResult?.(c.id, out[c.id]);
    }
  } finally {
    for (const name of sessions) {
      if (dev) await dev.reset(name);
      else await exec(cmuxCli(), ["browser", "repl", "reset", name]);
    }
    if (dev) await dev.close();
  }
  return out;
}

async function runAside(cases, origins, server) {
  const out = {};
  const ctx = { origins, server, backend: "aside", aside: (code) => exec("aside", ["repl", code]).then((r) => parseMarked(r.out) ?? { uncaught: `no result (exit ${r.code}): ${(r.err || r.out).trim().slice(-400)}` }) };
  for (const c of cases) {
    const t0 = Date.now();
    let r;
    if (c.custom) r = c.custom.aside ? await c.custom.aside(ctx).then((v) => ({ value: v }), (e) => ({ uncaught: String(e.message || e) })) : null;
    else if (dialectSource(c, "aside") == null) r = null;
    else r = await ctx.aside(wrap(c, "aside", origins));
    if (!r) continue;
    out[c.id] = { ...r, ms: Date.now() - t0 };
    log("aside", c, out[c.id]);
  }
  return out;
}

async function runChatgpt(cases, origins) {
  // The reference runtime is TypeScript loaded by ChatGPT's bundled node.
  const runtime = process.env.CUA_REFERENCE_RUNTIME ?? "/Applications/ChatGPT.app/Contents/Resources/cua_node";
  const ids = cases.filter((c) => (c.custom ? c.custom.chatgpt : dialectSource(c, "chatgpt") != null)).map((c) => c.id);
  const input = path.join(os.tmpdir(), `brepl-diff-cg-${process.pid}.json`);
  const output = input.replace(/\.json$/, ".out.json");
  fs.writeFileSync(input, JSON.stringify({ ids, origins }));
  const env = { ...process.env, CUA_REFERENCE_CODEX: process.env.CUA_REFERENCE_CODEX ?? path.join(os.homedir(), ".codex/plugins/.plugin-appserver/codex") };
  await new Promise((resolve) => {
    const child = spawn(path.join(runtime, "bin/node"), ["--experimental-strip-types", "--no-warnings", path.join(here, "chatgpt-runner.ts"), input, output], { stdio: "inherit", env });
    child.on("close", resolve);
  });
  const out = fs.existsSync(output) ? JSON.parse(fs.readFileSync(output, "utf8")) : {};
  fs.rmSync(input, { force: true });
  fs.rmSync(output, { force: true });
  return out;
}

function log(backend, c, r) {
  const s = r.uncaught ? `UNCAUGHT ${r.uncaught.split("\n")[0].slice(0, 160)}` : JSON.stringify(r.value).slice(0, 160);
  console.log(`  ${backend} ${c.id} ${r.ms}ms ${s}`);
}

function meta(backend) {
  const m = { backend, recordedAt: new Date().toISOString() };
  if (backend === "aside") m.version = "Aside CLI (aside --version at record time)";
  if (backend === "cmux") {
    m.tag = (cmuxCli().match(/cmux DEV ([\w.-]+)\.app/) || [])[1] ?? null;
    m.sha = process.env.PARITY_CMUX_SHA ?? null;
  }
  return m;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const cases = (await loadCases()).filter((c) => (!args.only || c.id.includes(args.only) || c.file.includes(args.only)) && (!args.ids || args.ids.has(c.id)));
  // check: run cmux (dev driver or app) now and judge it against the
  // recorded reference evidence, without writing results.
  if (args.mode === "check") {
    const server = await startDiffServer();
    // A case that needs a person acting during the run runs only when asked for.
    const selected = cases.filter((c) => !(c.appOnly && args.backend === "cmux-dev") && !(c.requiresPerson && !process.env.PARITY_USER_CLICK_MARKER));
    let out;
    try {
      out = await runReplBackend(args.backend, selected, server.origins, server);
    } finally {
      await server.close();
    }
    const fresh = { meta: {}, cases: Object.fromEntries(Object.entries(out).map(([id, r]) => [id, normalizeStrings(r, server.origins)])) };
    const results = { cmux: args.backend === "cmux" ? fresh : { cases: {} }, "cmux-dev": args.backend === "cmux-dev" ? fresh : { cases: {} }, aside: readResults("aside"), chatgpt: readResults("chatgpt") };
    let bad = 0;
    for (const row of allVerdicts(selected, results)) {
      if (row.cmuxProblems.length) {
        bad++;
        console.log(`FAIL ${row.id}: ${row.cmuxProblems.join("; ")}`);
      }
      for (const ref of REFERENCES) {
        const v = row.refs[ref];
        if (v.verdict === "cmux-worse") {
          bad++;
          console.log(`WORSE ${ref} ${row.id}: ${v.reason}`);
        }
      }
    }
    console.log(`${selected.length} cases, ${bad} failures or cmux-worse verdicts`);
    process.exitCode = bad ? 1 : 0;
    return;
  }
  if (args.mode === "run") {
    const server = await startDiffServer();
    // A case that needs a person acting during the run runs only when asked for.
    const selected = cases.filter((c) => !(c.appOnly && args.backend === "cmux-dev") && !(c.requiresPerson && !process.env.PARITY_USER_CLICK_MARKER));
    let out;
    try {
      if (args.backend === "aside") out = await runAside(selected, server.origins, server);
      else if (args.backend === "chatgpt") out = await runChatgpt(selected, server.origins);
      else {
        const partial = readResults(args.backend);
        out = await runReplBackend(args.backend, selected, server.origins, server, (id, r) => {
          partial.cases[id] = normalizeStrings(r, server.origins);
          writeResults(args.backend, partial);
        });
      }
    } finally {
      await server.close();
    }
    const prev = readResults(args.backend);
    const merged = { meta: { ...prev.meta, ...meta(args.backend) }, cases: { ...prev.cases } };
    if (args.backend === "aside") merged.meta.version = (await exec("aside", ["--version"])).out.trim();
    for (const [id, r] of Object.entries(out)) merged.cases[id] = normalizeStrings(r, server.origins);
    // Drop results of cases that no longer exist.
    const all = new Set((await loadCases()).map((c) => c.id));
    for (const id of Object.keys(merged.cases)) if (!all.has(id)) delete merged.cases[id];
    writeResults(args.backend, merged);
    console.log(`${Object.keys(out).length} ${args.backend} results recorded`);
    return;
  }
  if (args.mode === "verdicts") {
    const results = Object.fromEntries(["cmux", "cmux-dev", ...REFERENCES].map((b) => [b, readResults(b)]));
    const rows = allVerdicts(cases, results);
    const totals = {};
    for (const row of rows) {
      if (row.cmuxProblems.length) {
        totals["cmux:fails-expect"] = (totals["cmux:fails-expect"] ?? 0) + 1;
        console.log(`FAIL ${row.id} [${row.cmuxBackend}]: ${row.cmuxProblems.join("; ")}`);
      }
      for (const ref of REFERENCES) {
        const v = row.refs[ref];
        totals[`${ref}:${v.verdict}`] = (totals[`${ref}:${v.verdict}`] ?? 0) + 1;
        if (v.verdict === "cmux-worse" || (args.verbose && v.verdict === "not-run")) console.log(`${v.verdict.toUpperCase()} ${ref} ${row.id} [${row.cmuxBackend}]: ${v.reason}`);
      }
    }
    console.log(JSON.stringify(totals, null, 1));
    process.exitCode = Object.keys(totals).some((k) => k.endsWith(":cmux-worse") || k === "cmux:fails-expect") ? 1 : 0;
    return;
  }
  // Writes each capability's `cases` (every case that lists the member),
  // replacing the old single `proof` key.
  if (args.mode === "sync-capabilities") {
    const file = path.join(here, "..", "capabilities.json");
    const caps = JSON.parse(fs.readFileSync(file, "utf8"));
    const index = new Map();
    for (const c of cases) for (const m of c.members ?? []) index.set(m, [...(index.get(m) ?? []), c.id]);
    const apply = (ref, name, entry) => {
      if (entry.excluded !== undefined) return entry;
      const { proof, ...rest } = entry;
      return { ...rest, cases: index.get(`${ref}:${name}`) ?? [] };
    };
    for (const [group, members] of Object.entries(caps.aside)) {
      if (group === "$comment") continue;
      for (const [name, entry] of Object.entries(members)) members[name] = apply("aside", group === "globals" ? name : `${group}.${name}`, entry);
    }
    for (const [name, entry] of Object.entries(caps.chatgpt)) caps.chatgpt[name] = apply("chatgpt", name, entry);
    fs.writeFileSync(file, JSON.stringify(caps, null, 2) + "\n");
    const empty = [];
    for (const [ref, group] of [["aside", caps.aside], ["chatgpt", { chatgpt: caps.chatgpt }]]) {
      for (const [g, members] of Object.entries(group)) for (const [name, e] of Object.entries(members)) if (e.cases && !e.cases.length) empty.push(`${ref} ${g === "globals" || g === "chatgpt" ? name : `${g}.${name}`}`);
    }
    console.log(empty.length ? `members without cases:\n  ${empty.join("\n  ")}` : "every member has cases");
    return;
  }
  if (args.mode === "report") {
    const { writeReport } = await import("./report.mjs");
    writeReport(cases);
    return;
  }
  throw new Error("usage: run.mjs run --backend cmux-dev|cmux|aside|chatgpt | verdicts | report");
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch((e) => {
    console.error(e.stack || e.message);
    process.exitCode = 2;
  });
}
