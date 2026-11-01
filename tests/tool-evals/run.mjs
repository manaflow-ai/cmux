#!/usr/bin/env bun
// Tool evals: does a model use cmux's MCP tools (code mode or every tool) and CLI
// correctly? Replays one Claude Code turn per case on a real model; the cmux side is
// real (an ephemeral headless daemon, `cmux mcp serve`, the CLI). See README.md.
import { execFile, spawn } from "node:child_process";
import { chmodSync, copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { promisify } from "node:util";
import { gunzipSync } from "node:zlib";
import { capture, normalize } from "../agent-evals/snapshot.mjs";
import { caseVerdict, cliTool, gradeCalls, gradeState, verdict } from "./grade.mjs";
import { evalAgentStub, openSession, SSH_OPTS } from "./session.mjs";
import { runClaudeSdk, runCodexAppServer } from "./agents-sdk.mjs";
import { shellProfile } from "./live-guard.mjs";
import { TASKS } from "../agent-evals/tasks.mjs";

const pexec = promisify(execFile);
const HERE = import.meta.dir;
const REPO = resolve(HERE, "../..");
const arg = (name, fallback) => {
  const i = process.argv.indexOf(`--${name}`);
  return i > 0 ? process.argv[i + 1] : fallback;
};
const flag = (name) => process.argv.includes(`--${name}`);

const MODELS = ["claude-sonnet-5-5", "claude-opus-5-5", "claude-haiku-5-5"];
// USD per million tokens (cache writes at the 5-minute rate).
const PRICES = {
  "claude-sonnet-5-5": { input: 2, output: 10, cacheWrite: 2.5, cacheRead: 0.2 },
  "claude-opus-5-5": { input: 4, output: 20, cacheWrite: 5, cacheRead: 0.2 },
  "claude-haiku-5-5": { input: 0.1, output: 0.5, cacheWrite: 0.125, cacheRead: 0.01 },
};
const MODEL = arg("model", "claude-sonnet-5-5");
/** `openrouter:<id>` runs any OpenRouter model in the generic harness (an OpenCode-like agent). */
const OPENROUTER = MODEL.startsWith("openrouter:") ? MODEL.slice("openrouter:".length) : null;
/** `claude-cli:<model>` / `codex-cli:<model>` run the real CLI on this machine (cmux MCP behind mcp-log.mjs). */
const CLI_AGENT = /^(claude|codex)-cli:(.+)$/.exec(MODEL);
const HARNESS = CLI_AGENT ? `${CLI_AGENT[1]}-cli` : OPENROUTER ? "generic" : "claude";
if (!OPENROUTER && !CLI_AGENT && !MODELS.includes(MODEL)) throw new Error(`--model is one of ${MODELS.join(", ")} openrouter:<id>, claude-cli:<id> or codex-cli:<id>`);

const SURFACES = (arg("surface", "code")).split(",");
const CLI = arg("cli", process.env.CMUX_EVAL_CLI ?? "/Applications/cmux NIGHTLY.app/Contents/Resources/bin/cmux");
const OUT = resolve(arg("out", join(REPO, "artifacts/tool-evals", new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19))));
const SAMPLES = Number(arg("samples", "2"));
const CONCURRENCY = Number(arg("concurrency", "4"));
const MAX_STEPS = Number(arg("max-steps", "20"));
const EFFORT = arg("effort", "medium");
const CLI_TIMEOUT_S = Number(arg("timeout", "600"));
const BASE_URL = process.env.ANTHROPIC_BASE_URL ?? "http://sr2-gateway.tail137216.ts.net:4016";
const AUTH = process.env.ANTHROPIC_AUTH_TOKEN ?? process.env.ANTHROPIC_API_KEY ?? "";
const OVERLAY = arg("overlay", null) ? JSON.parse(readFileSync(arg("overlay"), "utf8")) : null;
const TEMPLATE = JSON.parse(gunzipSync(readFileSync(join(HERE, "templates/claude.json.gz"))).toString());
const PREFIX = "mcp__cmux__";

// ---------- cases ----------
function loadCases() {
  const files = arg("cases", null)?.split(",") ?? readdirSync(join(HERE, "cases")).filter((f) => f.endsWith(".ndjson")).map((f) => join(HERE, "cases", f));
  const all = files.flatMap((f) => readFileSync(f, "utf8").split("\n").filter((l) => l.trim() && !l.startsWith("//")).map((l) => JSON.parse(l)));
  // The headless agent-evals tasks run here too, graded on state alone.
  for (const t of TASKS.filter((t) => t.tier === "headless")) {
    all.push({ id: `ae-${t.id}`, area: "agent-evals", kind: "guard", source: "tests/agent-evals/tasks.mjs", prompt: t.prompt, setup: t.setup, expect: { state: t.checks } });
  }
  const ids = arg("case", null)?.split(",");
  // App-tier cases need a cmux app (browser, Markdown): skipped unless --tier app.
  const tier = arg("tier", "headless");
  return all.filter((c) => (!ids || ids.includes(c.id)) && (ids || tier === "all" || (c.tier ?? "headless") === tier));
}

// ---------- the request the harness would send ----------
/** Applies an overlay (fast copy experiments without a rebuild): { instructions, exec, tools: { name: description } }. */
function overlaid(tools, instructions) {
  if (!OVERLAY) return { tools, instructions };
  return {
    instructions: OVERLAY.instructions ?? instructions,
    tools: tools.map((t) => ({
      ...t,
      description: t.name === "cmux_exec" && OVERLAY.exec ? OVERLAY.exec : (OVERLAY.tools?.[t.name] ?? t.description),
    })),
  };
}

const apiTool = (t) => ({ name: PREFIX + t.name, description: t.description ?? "", input_schema: t.inputSchema ?? { type: "object" } });

/** First request of the turn: the captured Claude Code prompt with this cmux's text in it. */
function buildBase(surface, session) {
  const { tools, instructions } = surface === "cli" ? { tools: [], instructions: "" } : overlaid(session.tools, session.instructions);
  const mcpNames = tools.map((t) => PREFIX + t.name);
  const env = TEMPLATE.env
    .replace("{{DEFERRED}}", [...TEMPLATE.deferred, ...mcpNames].join("\n"))
    .replace("{{MCP_INSTRUCTIONS}}", instructions ? `# MCP Server Instructions\n\nThe following MCP servers have provided instructions for how to use their tools and resources:\n\n## cmux\n${instructions}\n\n` : "")
    .replaceAll("{{CWD}}", session.work)
    .replaceAll("{{MODEL}}", MODEL);
  return { system: TEMPLATE.system, tools: TEMPLATE.tools, reminders: TEMPLATE.reminders, env, deferred: tools.map(apiTool) };
}

/**
 * The generic harness: what an OpenCode-like agent sends. A plain coding-agent system prompt,
 * four native tools, and every cmux MCP tool listed directly as `cmux_<tool>` (no tool search),
 * with the server's instructions in the system prompt.
 */
const GENERIC_SYSTEM = `You are an interactive coding agent running in the user's terminal. Use the tools to do what the user asks, then reply briefly with what you did. Do the work yourself; ask only when the request is ambiguous.`;
const GENERIC_TOOLS = [
  { name: "bash", description: "Run a shell command in the working directory and return its output.", input_schema: { type: "object", properties: { command: { type: "string" } }, required: ["command"] } },
  { name: "read", description: "Read a file.", input_schema: { type: "object", properties: { file_path: { type: "string" } }, required: ["file_path"] } },
  { name: "write", description: "Write a file.", input_schema: { type: "object", properties: { file_path: { type: "string" }, content: { type: "string" } }, required: ["file_path", "content"] } },
  { name: "edit", description: "Replace old_string with new_string in a file.", input_schema: { type: "object", properties: { file_path: { type: "string" }, old_string: { type: "string" }, new_string: { type: "string" } }, required: ["file_path", "old_string", "new_string"] } },
];
const GENERIC_NAMES = { bash: "Bash", read: "Read", write: "Write", edit: "Edit" };
/** The runner's tool name for a generic harness tool name. */
const internalName = (name) => (Object.hasOwn(GENERIC_NAMES, name) ? GENERIC_NAMES[name] : name.startsWith("cmux_") ? PREFIX + name.slice(5) : name);

function buildGenericBase(surface, session) {
  const { tools, instructions } = surface === "cli" ? { tools: [], instructions: "" } : overlaid(session.tools, session.instructions);
  const env = `Working directory: ${session.work}\nPlatform: darwin\nToday's date: 2026-10-27\nThe terminal you run in is a cmux terminal.` +
    (instructions ? `\n\n# MCP server cmux\n${instructions}` : "");
  const mcp = tools.map((t) => ({ name: `cmux_${t.name}`, description: t.description ?? "", input_schema: t.inputSchema ?? { type: "object" } }));
  return { system: [{ type: "text", text: `${GENERIC_SYSTEM}\n\n${env}` }], tools: [...GENERIC_TOOLS, ...mcp], reminders: [], env: "", deferred: [] };
}

function firstMessages(base, testCase) {
  if (HARNESS === "generic") {
    const text = testCase.context ? `${testCase.context}\n\n${testCase.prompt}` : testCase.prompt;
    return [{ role: "user", content: [{ type: "text", text }] }];
  }
  const user = [...base.reminders.map((text) => ({ type: "text", text })), { type: "text", text: testCase.prompt }];
  if (testCase.context) user.unshift({ type: "text", text: `<system-reminder>\n${testCase.context}\n</system-reminder>` });
  return [{ role: "user", content: user }, { role: "system", content: [{ type: "text", text: base.env }] }];
}

// ---------- tools the model calls ----------
function searchTools(deferred, query, max) {
  if (query.startsWith("select:")) {
    const names = query.slice(7).split(",").map((s) => s.trim());
    return deferred.filter((t) => names.includes(t.name));
  }
  const words = query.toLowerCase().split(/\s+/).filter(Boolean);
  const required = words.filter((w) => w.startsWith("+")).map((w) => w.slice(1));
  const score = (t) => {
    const name = t.name.toLowerCase();
    if (!required.every((w) => name.includes(w))) return 0;
    return words.reduce((s, w) => s + (name.includes(w.replace(/^\+/, "")) ? 3 : 0) + (t.description.toLowerCase().includes(w) ? 1 : 0), 0);
  };
  return deferred.map((t) => [score(t), t]).filter(([s]) => s > 0).sort((a, b) => b[0] - a[0]).slice(0, max).map(([, t]) => t);
}

/** A shell with `cmux` routed to the eval session and logged; other commands run in the work dir. */
async function runBash(sample, command) {
  const dir = sample.dir;
  // macOS: a sandbox that blocks every cmux socket but the sample's own and writes outside its
  // directories. Linux (the rbx builder, which runs no other cmux): plain bash; the graders'
  // session check still catches an agent that names another socket.
  const [exe, args] = process.platform === "darwin"
    ? ["sandbox-exec", ["-f", join(dir, "sandbox.sb"), "bash", "-c", command]]
    : ["bash", ["-c", command]];
  const { stdout, stderr, code } = await pexec(
    exe,
    args,
    { cwd: sample.session.work, env: sample.shellEnv, timeout: 60_000, maxBuffer: 8 << 20 },
  ).then((r) => ({ ...r, code: 0 }), (e) => ({ stdout: e.stdout ?? "", stderr: e.stderr ?? String(e.message), code: e.code ?? 1 }));
  const out = `${stdout}${stderr}`.slice(0, 30_000);
  return { text: out || (code ? `(exit ${code})` : "(no output)"), isError: code !== 0 };
}

/** One shell word, single-quoted. */
const shq = (text) => `'${String(text).replaceAll("'", "'\\''")}'`;

function shellFixtures(sample) {
  const { dir, session } = sample;
  mkdirSync(join(dir, "bin"), { recursive: true });
  const shim = join(dir, "bin/cmux");
  // With --remote-daemon the shell's cmux is the build under test on the daemon's host (its
  // app socket is there too, forwarded by the MCP server's ssh), not this Mac's --cli build:
  // an agent that uses the CLI must meet the same build as its MCP tools. It runs as `cmux`
  // (`exec -a`): the binary's name picks the curated `cmux` CLI over the `cmux-tui` grammar.
  const run = REMOTE
    ? `exec ssh ${SSH_OPTS.map(shq).join(" ")} ${shq(REMOTE.host)} cd ${shq(shq(session.work))} '&&' export ${["CMUX_TUI_SOCKET", "CMUX_TUI_TERMINAL_ID", "CMUX_SOCKET_PATH", "CMUX_NEXT_CONFIG_FILE"].map((k) => shq(shq(`${k}=${session.env[k]}`))).join(" ")} '&&' exec bash -c ${shq(shq('exec -a cmux "$0" "$@"'))} ${shq(shq(REMOTE.cli))} \${@:+$(printf ' %q' "$@")}`
    : `exec ${JSON.stringify(CLI)} "$@"`;
  writeFileSync(
    shim,
    `#!/bin/bash\njq -cn '{argv:$ARGS.positional}' --args -- "$@" >> ${JSON.stringify(join(dir, "cli.jsonl"))}\n${run}\n`,
  );
  chmodSync(shim, 0o755);
  // The stub helper agent of agent-evals' subagents-right: records the terminal it ran in.
  mkdirSync(join(dir, "markers"), { recursive: true });
  const stub = join(dir, "bin/cmux-eval-agent");
  writeFileSync(stub, evalAgentStub(dir));
  chmodSync(stub, 0o755);
  writeFileSync(join(dir, "sandbox.sb"), shellProfile({ sessionName: session.name, work: session.work, dir }));
  sample.shellEnv = { ...session.env, PATH: `${join(dir, "bin")}:${dirname(CLI)}:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin`, HOME: session.work };
}

async function answerTool(sample, use) {
  const { name, input } = use;
  if (name === "ToolSearch") {
    const found = searchTools(sample.base.deferred, String(input.query ?? ""), Number(input.max_results ?? 5));
    for (const t of found) if (!sample.tools.some((x) => x.name === t.name)) sample.tools.push(t);
    return { text: found.length ? found.map((t) => `Loaded ${t.name}`).join("\n") : "No matching deferred tools found", isError: false };
  }
  if (name.startsWith(PREFIX)) {
    const tool = name.slice(PREFIX.length);
    const r = await sample.session.route(tool).request("tools/call", { name: tool, arguments: input }).catch((e) => ({ isError: true, content: [{ type: "text", text: String(e.message) }] }));
    const text = (r.content ?? []).map((c) => c.text ?? "").join("\n");
    const sc = r.structuredContent;
    if (tool === "cmux_exec") {
      sample.scripts.push(String(input.script ?? ""));
      for (const c of sc?.call_log ?? []) sample.ops.push({ via: "exec", tool: c.name, ok: c.ok !== false, error: c.error?.message ?? c.state });
      if (r.isError && !(sc?.call_log ?? []).length) sample.ops.push({ via: "exec", tool: "cmux_exec", ok: false, error: sc?.error?.message ?? text.slice(0, 200) });
      sample.docsCalls += (String(input.script ?? "").match(/cmux\.docs\(/g) ?? []).length;
    } else {
      sample.ops.push({ via: "mcp", tool, ok: !r.isError, input, error: r.isError ? text.slice(0, 200) : undefined });
    }
    return { text, isError: !!r.isError };
  }
  if (name === "Bash") {
    const command = String(input.command ?? "");
    sample.shell.push(command);
    const before = readLines(join(sample.dir, "cli.jsonl")).length;
    const r = await runBash(sample, command);
    for (const c of readLines(join(sample.dir, "cli.jsonl")).slice(before)) {
      sample.ops.push({ via: "cli", tool: cliTool(c.argv), ok: !r.isError, argv: c.argv, input: c.argv });
      sample.cliCalls.push(c);
    }
    return r;
  }
  if (name === "Read") {
    const r = await runBash(sample, `cat -n ${JSON.stringify(String(input.file_path ?? ""))} | head -${Number(input.limit ?? 2000)}`);
    return r;
  }
  if (name === "Write" || name === "Edit") {
    // Only inside the scratch directory, as the sandbox allows.
    const path = resolve(sample.session.work, String(input.file_path ?? ""));
    if (!path.startsWith(sample.session.work)) return { text: "Writes outside the working directory are not allowed here.", isError: true };
    if (name === "Write") {
      mkdirSync(dirname(path), { recursive: true });
      writeFileSync(path, String(input.content ?? ""));
      return { text: `File created successfully at: ${path}`, isError: false };
    }
    if (!existsSync(path)) return { text: `File does not exist: ${path}`, isError: true };
    const old = readFileSync(path, "utf8");
    const from = String(input.old_string ?? "");
    if (!old.includes(from)) return { text: "String to replace not found in file.", isError: true };
    writeFileSync(path, input.replace_all ? old.split(from).join(String(input.new_string ?? "")) : old.replace(from, String(input.new_string ?? "")));
    return { text: `The file ${path} has been updated successfully.`, isError: false };
  }
  return { text: `${name} is not available in this session.`, isError: true };
}

function readLines(path) {
  return existsSync(path) ? readFileSync(path, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l)) : [];
}

let jobSeq = 0;

// ---------- real CLIs on this machine ----------
const tomlString = (value) => JSON.stringify(String(value));

/** Runs Claude Code (Agent SDK) or Codex (app-server) on one case and fills the sample from its logs. */
async function runCliAgent(sample, testCase, surface) {
  const { dir, session } = sample;
  const mcpLog = join(dir, "mcp.jsonl");
  const mcp = {
    command: process.execPath,
    args: (() => {
      const server = session.mcpCommand(surface === "all" ? ["--all-tools"] : []);
      return [join(HERE, "mcp-log.mjs"), mcpLog, server.command, ...server.args];
    })(),
    env: {
      CMUX_TUI_SOCKET: session.socket,
      CMUX_TUI_TERMINAL_ID: session.origin.terminal_id,
      CMUX_SOCKET_PATH: session.env.CMUX_SOCKET_PATH,
      CMUX_NEXT_CONFIG_FILE: session.env.CMUX_NEXT_CONFIG_FILE,
      PATH: process.env.PATH,
    },
  };
  const env = { ...sample.shellEnv, HOME: process.env.HOME, PATH: `${join(dir, "bin")}:${dirname(CLI)}:${process.env.PATH}` };
  for (const k of Object.keys(env)) if (/^(ACPMUX|MUX)_/.test(k) || k === "CMUX_AGENT_SESSION") delete env[k];
  const prompt = testCase.context ? `${testCase.context}\n\n${testCase.prompt}` : testCase.prompt;
  const common = { model: CLI_AGENT[2], prompt, cwd: session.work, mcp, env, own: dir, effort: EFFORT, timeoutMs: CLI_TIMEOUT_S * 1000, allTools: surface === "all" };
  // A model route that is out of capacity (a 429, "no non-exhausted accounts", a dropped
  // stream) is not a cmux result: wait and try the same sample again, up to 4 times. Only a
  // turn that never reached the model is retried, so no cmux call runs twice.
  let out;
  for (let attempt = 0; ; attempt++) {
    out = CLI_AGENT[1] === "claude"
      ? await runClaudeSdk({ ...common, home: join(dir, "claude-home") })
      : await runCodexAppServer({ ...common, home: join(dir, "codex-home") });
    const capacity = /\b(429|503)\b|non-exhausted|rate limit|Reconnecting|responseStreamDisconnected|overloaded/i.test(out.error ?? "");
    const untouched = !existsSync(mcpLog) || !readFileSync(mcpLog, "utf8").includes('"tools/call"');
    if (!capacity || !untouched || attempt >= 4) break;
    await new Promise((r) => setTimeout(r, 30_000 * (attempt + 1) + Math.random() * 15_000));
  }
  sample.text = out.text;
  sample.steps = out.steps;
  Object.assign(sample.usage, out.usage);
  sample.shell.push(...out.shell);
  if (out.error && (!out.text || /^API Error/.test(out.text))) sample.agentError = out.error;
  // MCP calls and, for cmux_exec, the calls its scripts made.
  const log = readLines(mcpLog);
  const requests = new Map(log.filter((l) => l.dir === "in" && l.msg.method === "tools/call").map((l) => [l.msg.id, l.msg.params]));
  for (const l of log.filter((l) => l.dir === "out" && requests.has(l.msg.id))) {
    const { name: tool, arguments: input } = requests.get(l.msg.id);
    const r = l.msg.result ?? { isError: true, structuredContent: { error: l.msg.error } };
    const sc = r.structuredContent;
    const text = (r.content ?? []).map((c) => c.text ?? "").join("\n");
    if (tool === "cmux_exec") {
      sample.scripts.push(String(input?.script ?? ""));
      sample.docsCalls += (String(input?.script ?? "").match(/cmux\.docs\(/g) ?? []).length;
      for (const c of sc?.call_log ?? []) sample.ops.push({ via: "exec", tool: c.name, ok: c.ok !== false, error: c.error?.message ?? c.state });
      if (r.isError && !(sc?.call_log ?? []).length) sample.ops.push({ via: "exec", tool: "cmux_exec", ok: false, error: sc?.error?.message ?? text.slice(0, 200) });
    } else {
      sample.ops.push({ via: "mcp", tool, ok: !r.isError, input, error: r.isError ? text.slice(0, 200) : undefined });
    }
  }
  for (const c of readLines(join(dir, "cli.jsonl"))) {
    sample.ops.push({ via: "cli", tool: cliTool(c.argv), ok: true, argv: c.argv, input: c.argv });
    sample.cliCalls.push(c);
  }
}


// ---------- OpenRouter (OpenAI chat format) ----------
const OPENROUTER_KEY = process.env.OPENROUTER_API_KEY ?? "";
if (OPENROUTER && !OPENROUTER_KEY) throw new Error("openrouter models need OPENROUTER_API_KEY (~/.secrets/openrouter.env, or 1Password Employee/OpenRouter API Key)");

/** The runner's Messages-shaped request as an OpenAI chat request. */
function toChat(body) {
  const messages = [{ role: "system", content: body.system.map((b) => b.text).join("\n\n") }];
  for (const m of body.messages) {
    if (m.role === "assistant") {
      const text = m.content.filter((b) => b.type === "text").map((b) => b.text).join("\n");
      const calls = m.content.filter((b) => b.type === "tool_use").map((b) => ({ id: b.id, type: "function", function: { name: b.name, arguments: JSON.stringify(b.input ?? {}) } }));
      const reasoning = m.content.find((b) => b.type === "reasoning_details");
      messages.push({ role: "assistant", content: text || null, ...(calls.length ? { tool_calls: calls } : {}), ...(reasoning ? { reasoning_details: reasoning.details } : {}) });
    } else {
      const results = m.content.filter((b) => b.type === "tool_result");
      for (const r of results) messages.push({ role: "tool", tool_call_id: r.tool_use_id, content: typeof r.content === "string" ? r.content : JSON.stringify(r.content) });
      const text = m.content.filter((b) => b.type === "text").map((b) => b.text).join("\n\n");
      if (text) messages.push({ role: "user", content: text });
    }
  }
  return {
    model: OPENROUTER,
    messages,
    tools: body.tools.map((t) => ({ type: "function", function: { name: t.name, description: t.description, parameters: t.input_schema } })),
    max_tokens: 16000,
    reasoning: { effort: EFFORT === "max" || EFFORT === "xhigh" ? "high" : EFFORT },
    usage: { include: true },
  };
}

/** One OpenRouter turn, answered in the runner's Messages shape. */
async function callOpenRouter(body) {
  for (let attempt = 0; ; attempt++) {
    const res = await fetch("https://openrouter.ai/api/v1/chat/completions", {
      method: "POST",
      signal: AbortSignal.timeout(300_000),
      headers: { "content-type": "application/json", authorization: `Bearer ${OPENROUTER_KEY}`, "x-title": "cmux tool-evals" },
      body: JSON.stringify(toChat(body)),
    }).catch((error) => (attempt < 6 ? null : Promise.reject(error)));
    const text = res ? await res.text() : "";
    let data = null;
    try { data = JSON.parse(text); } catch {}
    // A dropped connection, rate limit, server error, or a 200 with no choice (an upstream
    // provider failed) is tried again; any other 4xx is final.
    const retry = !res || res.status === 429 || res.status >= 500 || (res.ok && !data?.choices?.length);
    if (res?.ok && data?.choices?.length) {
      const choice = data.choices[0];
      const msg = choice.message ?? {};
      const content = [];
      if (msg.content) content.push({ type: "text", text: msg.content });
      if (msg.reasoning_details?.length) content.push({ type: "reasoning_details", details: msg.reasoning_details });
      for (const call of msg.tool_calls ?? []) {
        let input = {};
        try { input = JSON.parse(call.function.arguments || "{}"); } catch { input = { _unparsed: call.function.arguments }; }
        content.push({ type: "tool_use", id: call.id, name: call.function.name, input });
      }
      const u = data.usage ?? {};
      const cached = u.prompt_tokens_details?.cached_tokens ?? 0;
      return {
        content,
        stop_reason: choice.finish_reason,
        usage: { input_tokens: (u.prompt_tokens ?? 0) - cached, output_tokens: u.completion_tokens ?? 0, cache_read_input_tokens: cached, cost: u.cost ?? 0 },
      };
    }
    if (retry && attempt < 6) {
      await new Promise((r) => setTimeout(r, Math.min(30_000, 2000 * 2 ** attempt)));
      continue;
    }
    throw new Error(`openrouter ${res?.status}: ${text.slice(0, 300)}`);
  }
}

// ---------- the model ----------
async function callModel(body) {
  for (let attempt = 0; ; attempt++) {
    const res = await fetch(`${BASE_URL}/v1/messages`, {
      signal: AbortSignal.timeout(300_000),
      method: "POST",
      headers: {
        "content-type": "application/json",
        "anthropic-version": "2023-06-01",
        authorization: `Bearer ${AUTH}`,
        "user-agent": "claude-cli/2.1.311 (external, sdk-cli)",
        "x-app": "cli",
        "anthropic-beta": "claude-code-20250219,interleaved-thinking-2025-05-14,context-management-2025-06-27",
      },
      body: JSON.stringify(body),
    }).catch((error) => (attempt < 8 ? null : Promise.reject(error)));
    if (!res) {
      // The model route dropped the connection (a gateway restart): try again.
      await new Promise((r) => setTimeout(r, Math.min(30_000, 2000 * 2 ** attempt)));
      continue;
    }
    const text = await res.text();
    if (res.ok) return JSON.parse(text);
    if (attempt < 4 && (res.status === 429 || res.status >= 500)) {
      await new Promise((r) => setTimeout(r, 2000 * 2 ** attempt));
      continue;
    }
    throw new Error(`model ${res.status}: ${text.slice(0, 300)}`);
  }
}

/** PTYs in use on this Mac (macOS caps them at kern.tty.ptmx_max, 511 by default). */
function ptysInUse() {
  if (process.platform !== "darwin") return 0;
  return readdirSync("/dev").filter((f) => /^ttys\d+$/.test(f)).length;
}
const PTY_LIMIT = Number(arg("pty-limit", "485"));
/** `--remote-daemon host:/path/to/cmux`: each sample's daemon runs on that ssh host. */
const REMOTE = arg("remote-daemon", null) ? { host: arg("remote-daemon").split(":")[0], cli: arg("remote-daemon").split(":").slice(1).join(":") } : null;

async function runSample(testCase, surface, index) {
  // The person's own cmux shares the PTY cap: a sample starts only while enough stay free.
  while (!REMOTE && ptysInUse() > PTY_LIMIT) await new Promise((r) => setTimeout(r, 5000));
  const dir = join(OUT, surface, testCase.id, `s${index}`);
  mkdirSync(dir, { recursive: true });
  const name = `te${process.pid}-${(jobSeq++).toString(36)}`;
  const session = await openSession({ cli: CLI, name, dir, allTools: surface === "all" ? true : surface === "hybrid" ? "hybrid" : false, setup: testCase.setup ?? [], noApp: !!testCase.noApp, remote: REMOTE });
  const sample = { dir, session, ops: [], shell: [], scripts: [], cliCalls: [], docsCalls: 0, text: "", steps: 0, usage: { input: 0, output: 0, cacheWrite: 0, cacheRead: 0 }, firstInput: 0 };
  try {
    for (const [file, body] of Object.entries(testCase.files ?? {})) {
      mkdirSync(dirname(join(session.work, file)), { recursive: true });
      writeFileSync(join(session.work, file), body);
      // The terminals run on the daemon's host: the case's files are there too.
      if (REMOTE) {
        const path = join(session.work, file);
        const script = `mkdir -p ${shq(dirname(path))} && echo ${shq(Buffer.from(body).toString("base64"))} | base64 -d > ${shq(path)}`;
        await new Promise((ok, fail) => execFile("ssh", [...SSH_OPTS, REMOTE.host, script], (error) => (error ? fail(error) : ok())));
      }
    }
    shellFixtures(sample);
    sample.base = HARNESS === "generic" ? buildGenericBase(surface, session) : buildBase(surface, session);
    sample.tools = [...sample.base.tools];
    const before = normalize(await capture(session.cmux));
    // From the prompt to the agent's last word: the time a person waits for the task.
    sample.started = Date.now();
    if (CLI_AGENT) {
      await runCliAgent(sample, testCase, surface);
      return await finishSample(sample, testCase, surface, index, before, name, [], "cli", sample.steps + 1);
    }
    const messages = firstMessages(sample.base, testCase);
    const harnessMessages = HARNESS === "generic" ? 0 : 2;
    let stop = "";
    for (; sample.steps < MAX_STEPS; sample.steps++) {
      const res = await (OPENROUTER ? callOpenRouter : callModel)({
        model: MODEL,
        max_tokens: 32000,
        system: sample.base.system,
        tools: sample.tools,
        messages,
        thinking: { type: "adaptive", display: "omitted" },
        output_config: { effort: EFFORT },
      });
      const u = res.usage ?? {};
      if (sample.steps === 0) sample.firstInput = (u.input_tokens ?? 0) + (u.cache_creation_input_tokens ?? 0) + (u.cache_read_input_tokens ?? 0);
      sample.usage.input += u.input_tokens ?? 0;
      sample.usage.output += u.output_tokens ?? 0;
      sample.usage.cacheWrite += u.cache_creation_input_tokens ?? 0;
      sample.usage.cacheRead += u.cache_read_input_tokens ?? 0;
      sample.usage.cost = (sample.usage.cost ?? 0) + (u.cost ?? 0);
      messages.push({ role: "assistant", content: res.content });
      sample.text += res.content.filter((b) => b.type === "text").map((b) => b.text).join("\n");
      const uses = res.content.filter((b) => b.type === "tool_use");
      stop = res.stop_reason;
      if (!uses.length) break;
      const results = [];
      for (const use of uses) {
        const r = await answerTool(sample, { ...use, name: internalName(use.name) }).catch((e) => ({ text: `harness: ${e.message}`, isError: true }));
        results.push({ type: "tool_result", tool_use_id: use.id, content: r.text, ...(r.isError ? { is_error: true } : {}) });
      }
      messages.push({ role: "user", content: results });
    }
    return await finishSample(sample, testCase, surface, index, before, name, messages.slice(harnessMessages), stop, sample.steps + 1);
  } finally {
    await session.close();
  }
}

/** Grades a finished sample and writes its row and transcript. */
async function finishSample(sample, testCase, surface, index, before, name, transcript, stop, steps) {
  const { dir, session } = sample;
  const seconds = sample.started ? Math.round((Date.now() - sample.started) / 100) / 10 : null;
  await new Promise((r) => setTimeout(r, 1500)); // commands the agent started print
  const beforeTabs = new Set(before.tabs.map((t) => t.id));
  const after = normalize(await capture(session.cmux, { textFor: (t) => !beforeTabs.has(t.id) }));
  const ctx = {
    before, after, origin: session.origin, aliases: session.aliases, answer: sample.text,
    calls: sample.cliCalls,
    // What the stand-in app opened (session.mjs OPEN_ACTIONS): kind, what, pane, tab.
    appOpens: existsSync(join(dir, "app-calls.jsonl")) ? readFileSync(join(dir, "app-calls.jsonl"), "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l)) : [],
    markers: (await session.markers()) ?? Object.fromEntries(readdirSync(join(dir, "markers")).map((r) => [r, readFileSync(join(dir, "markers", r), "utf8").trim()])), session: { name, sockets: [session.socket, session.env.CMUX_SOCKET_PATH] }, posts: [],
  };
  const checks = [...gradeState(testCase.expect?.state, ctx), ...gradeCalls(testCase.expect ?? {}, sample)];
  const row = {
    case: testCase.id, surface, sample: index, model: MODEL, ...verdict(checks), checks,
    steps, stop, ops: sample.ops.length, op_errors: sample.ops.filter((o) => !o.ok).length,
    docs_calls: sample.docsCalls, first_input_tokens: sample.firstInput, usage: sample.usage, cost_usd: cost(sample.usage),
    // Every token the model read (cached or not) and wrote over the task, and its wall time.
    tokens: (sample.usage.input ?? 0) + (sample.usage.cacheRead ?? 0) + (sample.usage.cacheWrite ?? 0) + (sample.usage.output ?? 0),
    seconds,
    // The CLI itself failed (no output, a crash): not a cmux result.
    ...(sample.agentError ? { pass: false, category: "agent_error", detail: sample.agentError } : {}),
  };
  writeFileSync(join(dir, "transcript.json"), JSON.stringify({ messages: transcript, ops: sample.ops, shell: sample.shell }, null, 1));
  writeFileSync(join(dir, "row.json"), JSON.stringify(row, null, 1));
  return row;
}

const cost = (u) => {
  if (OPENROUTER || CLI_AGENT) return Number((u.cost ?? 0).toFixed(4));
  const p = PRICES[MODEL];
  return Number(((u.input * p.input + u.output * p.output + u.cacheWrite * p.cacheWrite + u.cacheRead * p.cacheRead) / 1e6).toFixed(4));
};

// ---------- context report ----------
async function contextReport() {
  const rows = [];
  for (const surface of ["code", "all"]) {
    const s = await openSession({ cli: CLI, name: `tectx${process.pid}${surface}`, dir: join(OUT, "ctx", surface), allTools: surface === "all" });
    try {
      const { tools, instructions } = overlaid(s.tools, s.instructions);
      const schemas = JSON.stringify(tools.map(apiTool));
      let docs = {};
      if (surface === "code") {
        for (const q of ["pane split", "tab create terminal", "browser open", "workspace group", ""]) {
          const r = await s.mcp.request("tools/call", { name: "cmux_exec", arguments: { script: `return await cmux.docs(${JSON.stringify(q)})` } });
          docs[q || "(all)"] = (r.content ?? []).map((c) => c.text).join("").length;
        }
      }
      rows.push({ surface, tools: tools.length, instructions_chars: instructions.length, schema_chars: schemas.length, approx_tokens: Math.round((instructions.length + schemas.length) / 4), docs_answer_chars: docs });
    } finally {
      await s.close();
    }
  }
  console.log(JSON.stringify(rows, null, 1));
}

// ---------- main ----------
async function main() {
  if (flag("context")) return contextReport();
  const cases = loadCases();
  mkdirSync(OUT, { recursive: true });
  const baseline = arg("baseline", null) ? readLines(arg("baseline")) : [];
  const jobs = [];
  // `--rerun-errors`: keep the rows of an earlier run in --out and run again only the
  // samples whose agent or harness failed (a capacity outage), never a graded cmux result.
  const kept = flag("rerun-errors") ? readLines(join(OUT, "results.jsonl")).filter((r) => !["agent_error", "harness_error"].includes(r.category)) : [];
  const done = new Set(kept.map((r) => `${r.case}|${r.surface}|${r.sample}`));
  for (const c of cases) for (const surface of SURFACES) if (!c.surfaces || c.surfaces.includes(surface)) for (let i = 0; i < SAMPLES; i++) if (!done.has(`${c.id}|${surface}|${i}`)) jobs.push([c, surface, i]);
  const rows = [...kept];
  let next = 0;
  const worker = async () => {
    while (next < jobs.length) {
      const [c, surface, i] = jobs[next++];
      const row = await runSample(c, surface, i).catch((e) => ({ case: c.id, surface, sample: i, model: MODEL, pass: false, category: "harness_error", detail: String(e.stack ?? e) }));
      rows.push(row);
      writeFileSync(join(OUT, "results.jsonl"), `${rows.map((r) => JSON.stringify(r)).join("\n")}\n`);
      console.log(`${surface} ${c.id} s${i} ${row.pass ? "pass" : `FAIL ${row.category} ${row.failed ?? row.detail?.slice(0, 200) ?? ""}`} steps=${row.steps} ops=${row.ops} docs=${row.docs_calls} $${row.cost_usd}`);
    }
  };
  await Promise.all(Array.from({ length: Math.min(CONCURRENCY, jobs.length) }, worker));
  writeFileSync(join(OUT, "summary.md"), summarize(cases, rows, baseline));
  console.log(`\n${readFileSync(join(OUT, "summary.md"), "utf8")}`);
}

function summarize(cases, rows, baseline) {
  const lines = [`# Tool evals: ${MODEL}, ${SURFACES.join("+")}, ${SAMPLES} samples${OVERLAY ? `, overlay ${arg("overlay")}` : ""}`, ""];
  for (const surface of SURFACES) {
    const mine = rows.filter((r) => r.surface === surface);
    const byCase = cases.filter((c) => !c.surfaces || c.surfaces.includes(surface)).map((c) => {
      const s = mine.filter((r) => r.case === c.id);
      const b = baseline.filter((r) => r.case === c.id && r.surface === surface);
      return { c, v: caseVerdict(s), s, b: b.length ? caseVerdict(b) : null };
    });
    const passed = byCase.filter((x) => x.v.pass).length;
    const total = mine.reduce((s, r) => s + (r.cost_usd ?? 0), 0);
    const med = (k) => { const v = mine.map((r) => r[k]).filter((x) => x != null).sort((a, b) => a - b); return v[Math.floor(v.length / 2)] ?? "-"; };
    const sum = (k) => mine.reduce((acc, r) => acc + (r[k] ?? 0), 0);
    lines.push(`## ${surface}: ${passed}/${byCase.length} cases pass, $${total.toFixed(2)}, median first-request input ${med("first_input_tokens")} tokens, median steps ${med("steps")}, median docs calls ${med("docs_calls")}, median tokens ${med("tokens")}, median seconds ${med("seconds")}, total tokens ${sum("tokens")}, total seconds ${Math.round(sum("seconds"))}`, "");
    lines.push("| case | kind | result | baseline | failed check | median tokens | median s |", "| --- | --- | --- | --- | --- | --- | --- |");
    for (const { c, v, s, b } of byCase) {
      const failed = s.filter((r) => !r.pass).map((r) => r.failed ?? r.category).filter(Boolean);
      const caseMed = (k) => { const x = s.map((r) => r[k]).filter((n) => n != null).sort((p, q) => p - q); return x[Math.floor(x.length / 2)] ?? "-"; };
      lines.push(`| ${c.id} | ${c.kind} | ${v.pass ? "pass" : "FAIL"} ${v.samples - v.fails}/${v.samples} | ${b ? `${b.pass ? "pass" : "FAIL"} ${b.samples - b.fails}/${b.samples}` : ""} | ${[...new Set(failed)].join("; ").replaceAll("|", "\\|").slice(0, 160)} | ${caseMed("tokens")} | ${caseMed("seconds")} |`);
    }
    lines.push("");
  }
  return lines.join("\n");
}

await main();
