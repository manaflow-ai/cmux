#!/usr/bin/env bun
// Agent-evals runner (plans/cmux-next/agent-evals-DESIGN.md).
//
//   bun tests/agent-evals/run.mjs --agents claude:cli,codex:mcp --tasks all --parallel 3
//
// Every task run gets its own ephemeral, headless cmux session started with a
// scrubbed environment, so nothing reaches the user's running app or sessions.
// The agent runs inside the session's origin terminal, like a user's agent.
import { execFile, spawn } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { promisify } from "node:util";
import { AGENTS, NO_LOGIN_PATTERNS } from "./agents.mjs";
import { gradeTask } from "./grade.mjs";
import { renderResults } from "./report.mjs";
import { capture, normalize } from "./snapshot.mjs";
import { TASKS } from "./tasks.mjs";
import { PLAN_MD, startFixtureServer } from "./fixtures.mjs";

const pexec = promisify(execFile);
const HERE = import.meta.dir;
const REPO = resolve(HERE, "../..");

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i > 0 ? process.argv[i + 1] : fallback;
}
const RUN = arg("run", new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19));
const OUT = resolve(arg("out", join(REPO, "artifacts/agent-evals", RUN)));
const TIMEOUT_S = Number(arg("timeout", "600"));
const PARALLEL = Number(arg("parallel", "3"));
const TIER = arg("tier", "headless");
const REAL_CLI = arg("cli", process.env.CMUX_EVAL_CLI ?? "/Applications/cmux NIGHTLY.app/Contents/Resources/bin/cmux");
const APP_SOCKET = arg("app-socket", null);
// The agent's own service dropped mid-task: an infra failure, not a cmux-use failure.
const INFRA_ERROR = [/WritableIterable is closed/, /Connection lost, reconnecting/, /API Error: 5\d\d/, /database is locked/];
const PREFACE = "(You are running inside a terminal in cmux.)\n\n";

const taskIds = arg("tasks", "all");
const tasks = TASKS.filter((t) => (TIER === "all" || t.tier === TIER) && (taskIds === "all" || taskIds.split(",").includes(t.id)));
if (tasks.some((t) => t.tier === "app") && !APP_SOCKET) {
  console.error("app-tier tasks need --app-socket (a cmux-next app that owns the eval session)");
  process.exit(2);
}
const runs = arg("agents", "oracle:cli,noop:cli")
  .split(",")
  .map((spec) => {
    const [agent, surface = "cli"] = spec.split(":");
    if (!AGENTS[agent]) throw new Error(`unknown agent ${agent}`);
    if (!AGENTS[agent].surfaces.includes(surface)) throw new Error(`${agent} has no ${surface} surface`);
    return { agent, surface };
  });

/** The environment for the eval daemon and everything in it. */
function evalEnv(dir) {
  const env = {};
  for (const [k, v] of Object.entries(process.env)) {
    if (/^(CMUX|ACPMUX|MUX)[A-Z0-9_]*$/.test(k)) continue;
    env[k] = v;
  }
  env.CMUX_NEXT_CONFIG_FILE = join(dir, "cmux-next.json");
  // A path that does not exist: app commands fail instead of reaching the user's app.
  env.CMUX_SOCKET_PATH = join(dir, "no-app.sock");
  // Login shells (codex runs `zsh -lc`) rebuild PATH; this ZDOTDIR puts the shim first again.
  env.ZDOTDIR = join(dir, "zdot");
  env.PATH = `${join(dir, "bin")}:${dirname(REAL_CLI)}:${env.PATH}`;
  if (APP_SOCKET) env.CMUX_SOCKET_PATH = APP_SOCKET;
  return env;
}

function writeFixtures(dir, task, session, work) {
  mkdirSync(join(dir, "bin"), { recursive: true });
  mkdirSync(join(dir, "zdot"), { recursive: true });
  for (const f of [".zshenv", ".zprofile", ".zshrc", ".zlogin"]) {
    writeFileSync(
      join(dir, "zdot", f),
      `ZDOTDIR="$HOME"; [ -f "$HOME/${f}" ] && source "$HOME/${f}"; ZDOTDIR=${JSON.stringify(join(dir, "zdot"))}\nexport PATH=${JSON.stringify(join(dir, "bin"))}:"$PATH"\n`,
    );
  }
  mkdirSync(join(dir, "markers"), { recursive: true });
  mkdirSync(join(dir, "work"), { recursive: true });
  writeFileSync(join(dir, "cmux-next.json"), JSON.stringify({ mcp: { enabled: true } }));
  mkdirSync(join(work, "notes"), { recursive: true });
  writeFileSync(join(work, "notes/PLAN.md"), PLAN_MD);
  const prompt = task.prompt.replaceAll("{fixture}", FIXTURE?.url ?? "http://127.0.0.1:9").replaceAll("{workdir}", work);
  writeFileSync(join(dir, "prompt.txt"), PREFACE + prompt);
  // The cmux shim: log argv, then run the real CLI.
  const shim = join(dir, "bin/cmux");
  writeFileSync(
    shim,
    `#!/bin/bash\nif [ -f ${JSON.stringify(join(dir, "calls.on"))} ]; then jq -cn --arg t "$(date +%s)" '{argv:$ARGS.positional,t:($t|tonumber)}' --args -- "$@" >> ${JSON.stringify(join(dir, "calls.jsonl"))}; fi\nexec ${JSON.stringify(REAL_CLI)} "$@"\n`,
  );
  // The helper "agent" for subagents-right: records the terminal it ran in, then stays up.
  const stub = join(dir, "bin/cmux-eval-agent");
  writeFileSync(
    stub,
    `#!/bin/bash\nrole=""\nwhile [ $# -gt 0 ]; do case "$1" in --role) role="$2"; shift 2;; --role=*) role="\${1#--role=}"; shift;; *) shift;; esac; done\n[ -z "$role" ] && { echo "usage: cmux-eval-agent --role NAME" >&2; exit 2; }\necho "\${CMUX_TUI_TERMINAL_ID:-unknown}" > "${join(dir, "markers")}/$role"\necho "agent $role ready"\nexec sleep 3600\n`,
  );
  // MCP: code mode against this session, with a tee of the requests.
  const mcp = join(dir, "mcp.sh");
  writeFileSync(mcp, `#!/bin/bash\ntee -a ${JSON.stringify(join(dir, "mcp.jsonl"))} | ${JSON.stringify(REAL_CLI)} mcp serve\n`);
  // MCP with every tool listed (the "mcp-all" surface), tee'd to the same log.
  const mcpAll = join(dir, "mcp-all.sh");
  writeFileSync(mcpAll, `#!/bin/bash\ntee -a ${JSON.stringify(join(dir, "mcp.jsonl"))} | ${JSON.stringify(REAL_CLI)} mcp serve --all-tools\n`);
  writeFileSync(join(dir, "mcp-all.json"), JSON.stringify({ mcpServers: { cmux: { command: mcpAll, args: [] } } }));
  for (const f of [shim, stub, mcp, mcpAll]) chmodSync(f, 0o755);
  writeFileSync(join(dir, "mcp-empty.json"), JSON.stringify({ mcpServers: {} }));
  writeFileSync(join(dir, "mcp.json"), JSON.stringify({ mcpServers: { cmux: { command: mcp, args: [] } } }));
  writeFileSync(join(dir, "opencode-mcp.json"), JSON.stringify({ mcp: { cmux: { type: "local", command: [mcp], enabled: true } } }));
  writeFileSync(join(dir, "session.txt"), session);
  // The agent may connect to no cmux socket but its own session's: not the
  // user's app, not their sessions, not other eval runs.
  writeFileSync(
    join(dir, "sandbox.sb"),
    [
      "(version 1)",
      "(allow default)",
      '(deny network-outbound (remote unix-socket (path-regex #"cmux")))',
      `(allow network-outbound (remote unix-socket (path-regex #"/${session.replace(/[.-]/g, "\\$&")}\\.sock$")))`,
      ...(APP_SOCKET ? [`(allow network-outbound (remote unix-socket (literal ${JSON.stringify(APP_SOCKET)})))`] : []),
      "",
    ].join("\n"),
  );
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function runOne({ agent, surface }, task, index) {
  const dir = join(OUT, `${agent}-${surface}`, task.id);
  mkdirSync(dir, { recursive: true });
  const session = `ae-${process.pid}-${index}`;
  const work = mkdtempSync(join(tmpdir(), "cmux-eval-work-"));
  writeFixtures(dir, task, session, work);
  const postsBefore = FIXTURE?.posts.length ?? 0;
  const env = evalEnv(dir);
  const cmux = async (args, { json = true } = {}) => {
    const full = ["--session", session, ...(APP_SOCKET ? ["--app-socket", APP_SOCKET] : []), ...(json ? ["--json"] : []), ...args];
    const { stdout } = await pexec(REAL_CLI, full, { env, maxBuffer: 64 << 20 });
    if (!json) return stdout;
    const parsed = JSON.parse(stdout);
    return parsed && typeof parsed === "object" && "value" in parsed && "revision" in parsed ? parsed.value : parsed;
  };
  const started = Date.now();
  const row = { agent, surface, task: task.id, run: RUN };
  const daemon = spawn(REAL_CLI, ["daemon", "start", "--session", session, "--ephemeral", "--headless"], {
    env,
    cwd: work,
    stdio: ["ignore", "ignore", "pipe"],
    detached: true,
  });
  daemon.stderr.on("data", () => {});
  try {
    for (let i = 0; i < 50; i++) {
      try {
        await cmux(["workspace", "list"]);
        break;
      } catch {
        await sleep(200);
      }
    }
    // Origin: the user's workspace with the agent's terminal.
    const created = await cmux(["workspace", "create", "--name", "home", "--cwd", work]);
    const origin = { workspace_id: created.workspace_id, screen_id: created.screen_id, pane_id: created.pane_id, tab_id: created.tab_id };
    const originTerm = created.terminal_id;
    const aliases = await runSetup(cmux, task, origin, work);
    await cmux(["workspace", origin.workspace_id, "focus"]);
    await cmux(["pane", origin.pane_id, "focus"]);
    const before = normalize(await capture(cmux));

    // Launch the agent in the origin terminal.
    const launch = join(dir, "launch.sh");
    writeFileSync(
      launch,
      [
        "#!/bin/bash",
        `export PATH=${JSON.stringify(env.PATH)}`,
        `EVAL_DIR=${JSON.stringify(dir)}`,
        `export ZDOTDIR=${JSON.stringify(env.ZDOTDIR)}`,
        `export CMUX_SOCKET_PATH=${JSON.stringify(env.CMUX_SOCKET_PATH)} CMUX_NEXT_CONFIG_FILE=${JSON.stringify(env.CMUX_NEXT_CONFIG_FILE)}`,
        `cd ${JSON.stringify(work)}`,
        // Preflight: the CLI reaches this session and no app.
        `sandbox-exec -f "$EVAL_DIR/sandbox.sb" cmux --json workspace list > "$EVAL_DIR/preflight-ws.json" 2>&1`,
        `if sandbox-exec -f "$EVAL_DIR/sandbox.sb" ${JSON.stringify(REAL_CLI)} --app-socket "$HOME/.local/state/cmux/cmux-nightly.sock" app ping > /dev/null 2>&1; then echo live-app-reachable >> "$EVAL_DIR/preflight-fail"; fi`,
        APP_SOCKET ? "true" : `if sandbox-exec -f "$EVAL_DIR/sandbox.sb" cmux --json identify > "$EVAL_DIR/preflight-identify.json" 2>&1; then echo app-reachable > "$EVAL_DIR/preflight-fail"; fi`,
        `grep -q ${JSON.stringify(origin.workspace_id)} "$EVAL_DIR/preflight-ws.json" || echo wrong-session >> "$EVAL_DIR/preflight-fail"`,
        `if [ -f "$EVAL_DIR/preflight-fail" ]; then echo 97 > "$EVAL_DIR/agent.exit"; exit 0; fi`,
        `touch "$EVAL_DIR/calls.on"`,
        `sandbox-exec -f "$EVAL_DIR/sandbox.sb" perl -e 'alarm shift; exec @ARGV' ${TIMEOUT_S} bash "$EVAL_DIR/agent.sh"`,
        `echo $? > "$EVAL_DIR/agent.exit.tmp"; mv "$EVAL_DIR/agent.exit.tmp" "$EVAL_DIR/agent.exit"`,
        "",
      ].join("\n"),
    );
    chmodSync(launch, 0o755);
    writeFileSync(join(dir, "agent.sh"), `D=${JSON.stringify(dir)}\n${AGENTS[agent].command({ dir, surface, task })}\n`);
    await cmux(["terminal", originTerm, "write", "--text", `clear; ${launch}\n`]);
    const deadline = Date.now() + (TIMEOUT_S + 30) * 1000;
    while (!existsSync(join(dir, "agent.exit")) && Date.now() < deadline) await sleep(1000);
    const exit = existsSync(join(dir, "agent.exit")) ? Number(readFileSync(join(dir, "agent.exit"), "utf8").trim()) : null;
    await sleep(2500); // let commands the agent started print before reading terminals
    const beforeTabs = new Set(before.tabs.map((t) => t.id));
    const afterRaw = await capture(cmux, { textFor: (t) => !beforeTabs.has(t.id) });
    const after = normalize(afterRaw);
    writeFileSync(join(dir, "ctx.json"), JSON.stringify({ origin, aliases, session, sockets: [env.CMUX_SOCKET_PATH] }, null, 1));
    writeFileSync(join(dir, "before.json"), JSON.stringify(before, null, 1));
    writeFileSync(join(dir, "after.json"), JSON.stringify(after, null, 1));

    const calls = readJsonl(join(dir, "calls.jsonl"));
    const mcpCalls = readJsonl(join(dir, "mcp.jsonl")).filter((m) => m.method === "tools/call");
    const markers = Object.fromEntries(
      readdirSync(join(dir, "markers")).map((role) => [role, readFileSync(join(dir, "markers", role), "utf8").trim()]),
    );
    const answer = AGENTS[agent].answer(dir);
        const grade = gradeTask(task, { before, after, origin, aliases, answer, calls, markers, session: { name: session, sockets: [env.CMUX_SOCKET_PATH] }, posts: FIXTURE?.posts.slice(postsBefore) ?? [] });
    const errText = `${read(join(dir, "agent.err"))}\n${read(join(dir, "agent.out")).slice(0, 4000)}`;
    Object.assign(row, grade, {
      wall_ms: Date.now() - started,
      calls: calls.length + mcpCalls.length,
      cli_calls: calls.length,
      mcp_calls: mcpCalls.length,
      help_reads: calls.filter((c) => c.argv.some((a) => a === "--help" || a === "-h" || a === "help" || a === "docs")).length,
      exit,
      ...AGENTS[agent].meta(dir),
    });
    if (existsSync(join(dir, "preflight-fail"))) {
      Object.assign(row, { pass: false, score: 0, category: "harness_error", detail: read(join(dir, "preflight-fail")).trim() });
    } else if (exit === null || exit === 142) {
      if (row.pass) row.timed_out = true;
      else Object.assign(row, { category: "timeout" });
    } else if (NO_LOGIN_PATTERNS.some((p) => p.test(errText)) && row.calls === 0) {
      Object.assign(row, { pass: false, score: 0, category: "no_login" });
    } else if (exit !== 0 && !row.pass && (row.calls === 0 || INFRA_ERROR.some((p) => p.test(errText)))) {
      Object.assign(row, { category: "agent_error" });
    }
  } catch (error) {
    Object.assign(row, { pass: false, score: 0, category: "harness_error", detail: String(error.stack ?? error), wall_ms: Date.now() - started, calls: 0 });
  } finally {
    await pexec(REAL_CLI, ["daemon", "stop", "--session", session, "--end-terminals", "--force"], { env }).catch(() => {});
    try {
      process.kill(-daemon.pid, "SIGTERM");
    } catch {}
    const sockDir = join(env.TMPDIR ?? tmpdir(), `cmux-tui-${process.getuid()}`);
    for (const f of existsSync(sockDir) ? readdirSync(sockDir) : []) {
      if (f.startsWith(`${session}.sock`)) rmSync(join(sockDir, f), { force: true });
    }
    rmSync(work, { recursive: true, force: true });
  }
  writeFileSync(join(dir, "row.json"), JSON.stringify(row, null, 1));
  return row;
}

async function runSetup(cmux, task, origin, work) {
  const aliases = {};
  for (const step of task.setup ?? []) {
    if (step.op === "workspace") {
      await cmux(["workspace", "create", "--name", step.name, "--cwd", work]);
    } else if (step.op === "split-right") {
      const r = await cmux(["pane", origin.pane_id, "split", "--right", "--viewport-width", "0.5"]);
      if (step.alias) aliases[step.alias] = r.pane_id;
      if (step.name) await cmux(["tab", r.tab_id, "rename", step.name]);
      if (step.run) await cmux(["terminal", r.terminal_id, "write", "--text", `${step.run}\n`]);
    } else if (step.op === "tab") {
      const pane = aliases[step.pane] ?? step.pane;
      const r = await cmux(["tab", "create", "terminal", "--pane", pane]);
      if (step.alias) aliases[step.alias] = r.tab_id;
      if (step.name) await cmux(["tab", r.tab_id, "rename", step.name]);
      if (step.run) await cmux(["terminal", r.terminal_id, "write", "--text", `${step.run}\n`]);
    } else {
      throw new Error(`unknown setup op ${step.op}`);
    }
  }
  if (Object.keys(aliases).length) await sleep(800);
  return aliases;
}

function read(path) {
  return existsSync(path) ? readFileSync(path, "utf8") : "";
}
function readJsonl(path) {
  return read(path)
    .split("\n")
    .filter(Boolean)
    .map((l) => {
      try {
        return JSON.parse(l);
      } catch {
        return null;
      }
    })
    .filter(Boolean);
}

// One fixture site per run for app-tier tasks (posts are sliced per task run;
// app-tier runs that post must not run in parallel with each other).
const FIXTURE = tasks.some((t) => t.tier === "app") ? startFixtureServer() : null;

async function main() {
  mkdirSync(OUT, { recursive: true });
  const jobs = runs.flatMap((r) => tasks.map((t) => [r, t]));
  const rows = [];
  // OpenCode keeps one SQLite database per user; parallel runs lock it.
  const LIMIT = { opencode: 1 };
  const running = {};
  const pending = jobs.map((job, i) => ({ job, i }));
  const worker = async () => {
    while (pending.length) {
      const k = pending.findIndex(({ job: [r] }) => (running[r.agent] ?? 0) < (LIMIT[r.agent] ?? Infinity));
      if (k < 0) {
        await sleep(500);
        continue;
      }
      const [{ job: [r, t], i }] = pending.splice(k, 1);
      running[r.agent] = (running[r.agent] ?? 0) + 1;
      const row = await runOne(r, t, i);
      running[r.agent] -= 1;
      rows.push(row);
      writeFileSync(join(OUT, "rows.jsonl"), `${rows.map((x) => JSON.stringify(x)).join("\n")}\n`);
      console.log(`${row.agent}:${row.surface} ${row.task} ${row.pass ? "pass" : `FAIL ${row.category}`} ${(row.score ?? 0).toFixed(2)} ${Math.round(row.wall_ms / 1000)}s calls=${row.calls}`);
    }
  };
  await Promise.all(Array.from({ length: Math.min(PARALLEL, jobs.length) }, worker));
  const md = renderResults({ run: RUN, date: new Date().toISOString().slice(0, 10), rows });
  writeFileSync(join(OUT, "RESULTS.md"), md);
  console.log(`\n${md}`);
  FIXTURE?.stop();
}

await main();
