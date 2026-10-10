#!/usr/bin/env node
// Browser REPL scenario runner. See tests/browser-parity/README.md.
//
//   node tests/browser-parity/run.mjs check  --backend cmux-dev [--only 03] [-v]
//   node tests/browser-parity/run.mjs record --backend oracle|cmux-dev [--only 03]
//   node tests/browser-parity/run.mjs run    --backend cmux|cmux-dev|oracle [--only 03]
//
// A scenario is REPL code in the one cmux API, split into cells by
// `// ---- cell` lines. `emit(key, value)` records a behavior value that the
// oracle (real Playwright on Chrome) owns; `emitCmux(key, value)` records a
// value whose format cmux defines (snapshot text, printing). A scenario whose
// header says `// oracle: skip (<reason>)` is cmux-owned throughout, and so is
// a cell marked `// ---- cell cmux-only`, which the oracle does not run.
import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { startFixtureServers } from "./lib/fixture-server.mjs";
import { normalize, diffValues } from "./lib/normalize.mjs";
import { makeTestDir, removeTestDir } from "./lib/test-dirs.mjs";

const root = path.dirname(fileURLToPath(import.meta.url));
const MARK = "@@PARITY@@";
const BACKENDS = ["cmux", "cmux-dev", "oracle"];

function parseArgs(argv) {
  const args = { mode: argv[0], backend: null, only: null, verbose: false };
  for (let i = 1; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--backend") args.backend = argv[++i];
    else if (a === "--only") args.only = argv[++i];
    else if (a === "-v" || a === "--verbose") args.verbose = true;
    else throw new Error(`unknown argument ${a}`);
  }
  if (!["record", "check", "run"].includes(args.mode) || !BACKENDS.includes(args.backend)) {
    throw new Error(`usage: run.mjs record|check|run --backend ${BACKENDS.join("|")} [--only PREFIX] [-v]`);
  }
  if (args.mode === "record" && args.backend === "cmux") throw new Error("record from oracle (behavior) or cmux-dev (cmux-owned format)");
  return args;
}

// Scenario files: a header comment, then cells.
export function loadScenario(file) {
  const text = fs.readFileSync(file, "utf8");
  const skip = /^\/\/ oracle: skip\b(.*)$/m.exec(text);
  const cells = [];
  let current = { session: null, capture: false, lines: [] };
  for (const line of text.split("\n")) {
    const m = /^\/\/ ---- cell\b(.*)$/.exec(line);
    if (m) {
      cells.push(current);
      const session = /session=([\w-]+)/.exec(m[1]);
      current = { session: session ? session[1] : null, capture: /\bcapture\b/.test(m[1]), cmuxOnly: /\bcmux-only\b/.test(m[1]), lines: [] };
      continue;
    }
    current.lines.push(line);
  }
  cells.push(current);
  return {
    name: path.basename(file, ".js"),
    oracleSkip: !!skip,
    cells: cells.map((c) => ({ session: c.session, capture: c.capture, cmuxOnly: !!c.cmuxOnly, body: c.lines.join("\n") })).filter((c) => c.body.split("\n").some((l) => l.trim() && !l.trim().startsWith("//"))),
  };
}

function prelude(origins) {
  const line = (extra) => `${JSON.stringify(MARK)} + JSON.stringify({ k, v: v === undefined ? null : v${extra} })`;
  return [
    `const PRIMARY = ${JSON.stringify(origins.primary)};`,
    `const PEER = ${JSON.stringify(origins.peer)};`,
    `const INSECURE = ${JSON.stringify(origins.insecure)};`,
    `const emit = (k, v) => console.log(${line("")});`,
    `const emitCmux = (k, v) => console.log(${line(", c: 1")});`,
  ].join("\n");
}

// Cells stay top-level code so their declarations persist in a named
// session; an uncaught error becomes an "__error__" value.
function wrapCell(origins, cell) {
  return `${prelude(origins)};\n${cell.body}`;
}

function exec(cmd, argv, { input, timeoutMs = 180_000, cwd } = {}) {
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

const backends = {
  // The engine-neutral runtime (Resources/browser-repl) in this process on
  // Playwright WebKit through the dev driver. No app build needed.
  async "cmux-dev"(cells) {
    const { runDevCells } = await import("./lib/dev-driver.mjs");
    return runDevCells(cells);
  },
  // Real Playwright on headless Google Chrome with a thin shim of the globals.
  async oracle(cells) {
    const { runOracleCells } = await import("./lib/oracle.mjs");
    return runOracleCells(cells);
  },
  // The app. PARITY_CMUX_CLI selects a tagged build's CLI; CMUX_SOCKET_PATH
  // its socket. Each cell is one CLI call; a named session is reset after.
  async cmux(cells, { scenario }) {
    const cli = process.env.PARITY_CMUX_CLI ?? "cmux";
    const suffix = Math.random().toString(36).slice(2, 8);
    const sessions = new Set();
    const outputs = [];
    // A new working directory for the scenario: the session's fs root, where
    // scenarios write and remove their files, never the checkout.
    const workDir = makeTestDir("parity-cmux-");
    try {
      for (const cell of cells) {
        const argv = ["browser", "repl"];
        if (cell.session) {
          const name = `parity-${scenario}-${cell.session}-${suffix}`;
          sessions.add(name);
          argv.push("--session", name);
        }
        argv.push("--eval", "-");
        const r = await exec(cli, argv, { input: cell.code, cwd: workDir });
        const lines = r.out.split("\n").filter((l) => !/^\[(ok|error) \| \d+ms\]$/.test(l.trim()));
        while (lines.length && !lines[lines.length - 1].trim()) lines.pop();
        outputs.push({ output: lines.join("\n"), error: r.code === 0 ? null : r.err.trim() || `exit ${r.code}` });
      }
    } finally {
      for (const name of sessions) await exec(cli, ["browser", "repl", "reset", name]);
      removeTestDir(workDir);
    }
    return outputs;
  },
};

function parseEmits(outputs, cells) {
  const emits = [];
  outputs.forEach(({ output, error }, i) => {
    const plain = [];
    for (const line of output.split("\n")) {
      const at = line.indexOf(MARK);
      if (at < 0) {
        plain.push(line);
        continue;
      }
      try {
        emits.push({ ...JSON.parse(line.slice(at + MARK.length)), cmuxOnly: cells[i].cmuxOnly });
      } catch {
        emits.push({ k: "__unparsed__", v: line });
      }
    }
    if (cells[i].capture) emits.push({ k: `output:${i + 1}`, v: plain.join("\n"), c: 1 });
    if (error) emits.push({ k: `__error__:${i + 1}`, v: String(error).split("\n")[0] });
  });
  return emits;
}

const goldenPath = (name) => path.join(root, "goldens", `${name}.json`);
const readGolden = (name) => (fs.existsSync(goldenPath(name)) ? JSON.parse(fs.readFileSync(goldenPath(name), "utf8")) : null);

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const dir = path.join(root, "scenarios");
  const files = fs.readdirSync(dir).filter((f) => f.endsWith(".js") && (!args.only || f.startsWith(args.only))).sort();
  const server = await startFixtureServers();
  let failures = 0;
  let total = 0;
  try {
    for (const file of files) {
      const scenario = loadScenario(path.join(dir, file));
      if (args.backend === "oracle" && scenario.oracleSkip) continue;
      total++;
      // `cmux-only` cells use APIs with no Playwright counterpart; all their
      // values are cmux-owned and the oracle does not run them.
      const cells = scenario.cells
        .filter((c) => !(c.cmuxOnly && args.backend === "oracle"))
        .map((c) => ({ ...c, code: wrapCell(server.origins, c) }));
      let outputs;
      try {
        outputs = await backends[args.backend](cells, { scenario: scenario.name });
      } catch (e) {
        outputs = [{ output: "", error: `backend failed: ${e.stack || e}` }];
        cells.length = 1;
      }
      const emits = parseEmits(outputs, cells).map((e) => ({ ...e, v: normalize(e.v, server.origins) }));
      // Behavior keys belong to the oracle unless the scenario skips it.
      const owner = (e) => (e.c || e.cmuxOnly || scenario.oracleSkip ? "cmux" : "oracle");
      if (args.mode === "run") {
        console.log(scenario.name);
        for (const e of emits) console.log(`  [${owner(e)}] ${e.k} = ${JSON.stringify(e.v).slice(0, 300)}`);
        if (args.verbose) console.log(outputs.map((o) => o.output).join("\n-----\n"));
        continue;
      }
      if (args.mode === "record") {
        const errors = emits.filter((e) => e.k.startsWith("__"));
        const want = args.backend === "oracle" ? "oracle" : "cmux";
        const golden = readGolden(scenario.name) ?? { oracle: {}, cmux: {} };
        golden[want] = {};
        for (const e of emits) if (!e.k.startsWith("__") && owner(e) === want) golden[want][e.k] = e.v;
        if (errors.length) {
          failures++;
          console.log(`NOT RECORDED ${scenario.name}: ${errors.map((e) => `${e.k}: ${e.v}`).join("; ").slice(0, 600)}`);
          continue;
        }
        fs.mkdirSync(path.dirname(goldenPath(scenario.name)), { recursive: true });
        fs.writeFileSync(goldenPath(scenario.name), JSON.stringify(golden, null, 2) + "\n");
        console.log(`recorded ${scenario.name}: ${Object.keys(golden[want]).length} ${want} values`);
        continue;
      }
      const golden = readGolden(scenario.name);
      if (!golden) {
        failures++;
        console.log(`FAIL ${scenario.name}: no golden`);
        continue;
      }
      const expected = args.backend === "oracle" ? { ...golden.oracle } : { ...golden.oracle, ...golden.cmux };
      const actual = {};
      const problems = [];
      for (const e of emits) {
        if (args.backend === "oracle" && owner(e) !== "oracle" && !e.k.startsWith("__")) continue;
        if (e.k in actual) problems.push(`key "${e.k}" emitted twice`);
        actual[e.k] = e.v;
      }
      problems.push(...diffValues(expected, actual));
      if (problems.length) {
        failures++;
        console.log(`FAIL ${scenario.name}`);
        for (const p of problems) console.log(`  ${p}`);
        if (args.verbose) console.log(outputs.map((o) => o.output).join("\n-----\n").slice(-4000));
      } else console.log(`PASS ${scenario.name}`);
    }
  } finally {
    await server.close();
  }
  if (args.mode !== "run") {
    console.log(`\n${total - failures}/${total} scenarios ${args.mode === "record" ? "recorded" : "match"}`);
    process.exitCode = failures ? 1 : 0;
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch((e) => {
    console.error(e.stack || e.message);
    process.exitCode = 2;
  });
}
