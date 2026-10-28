// Real agent harnesses through their SDKs (no TUI, no terminal per run):
// - Claude Code through the Claude Agent SDK (`query`), routed by ANTHROPIC_BASE_URL;
// - Codex through `codex app-server` (JSON-RPC on stdio), routed by its config's provider.
// Each gets the cmux MCP server behind mcp-log.mjs, so the run is graded on what it called,
// and a clean home (no skills, memory or MCP servers of this machine).
import { execFileSync, spawn } from "node:child_process";
import { chmodSync, copyFileSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { agentProfile } from "./live-guard.mjs";

const SDK_PATH = join(homedir(), ".bun/install/global/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs");
/** The installed Claude Code, found when a Claude run starts (a host without it runs other models). */
const claudeBin = () => process.env.CLAUDE_BIN ?? execFileSync("which", ["claude"]).toString().trim();

/**
 * On macOS each harness runs under `agentProfile` (live-guard.mjs): a model's `open <url>`
 * fails in the sample instead of opening the person's default browser or their cmux app.
 * It also may not read this machine's own agent skills (an old installed cmux skill sent
 * Codex to classic commands) or other samples' results (Codex searched them for the answer);
 * its own sample dir `own` stays readable. Returns [command, args] for spawn.
 */
function guarded(home, own, command, args) {
  if (process.platform !== "darwin") return [command, args];
  mkdirSync(home, { recursive: true });
  const profile = join(home, "live-guard.sb");
  const hidden = [join(homedir(), ".agents"), join(homedir(), ".claude", "skills"), join(homedir(), ".codex", "skills"), "/tmp/cmux-tool-evals/runs", "/private/tmp/cmux-tool-evals/runs"];
  const reads = [...hidden.map((p) => `(deny file-read* (subpath ${JSON.stringify(p)}))`), `(allow file-read* (subpath ${JSON.stringify(own)}))`];
  writeFileSync(profile, agentProfile().replace(/\n$/, `\n${reads.join("\n")}\n`));
  return ["sandbox-exec", ["-f", profile, command, ...args]];
}

/** An executable that runs the installed Claude Code under [`guarded`] (the SDK takes a path). */
function guardedClaude(home, own) {
  const [command, args] = guarded(home, own, claudeBin(), []);
  const wrapper = join(home, "claude-guarded");
  writeFileSync(wrapper, `#!/bin/sh\nexec ${[command, ...args].map((a) => JSON.stringify(a)).join(" ")} "$@"\n`);
  chmodSync(wrapper, 0o755);
  return wrapper;
}

/**
 * One Claude Code turn through the Agent SDK. `mcp` is {command, args, env} for the cmux
 * server. Returns {text, steps, usage, cost, shell, error}.
 */
export async function runClaudeSdk({ model, prompt, cwd, mcp, env, home, own, effort, timeoutMs, allTools }) {
  const { query } = await import(SDK_PATH);
  mkdirSync(home, { recursive: true });
  const abort = new AbortController();
  const timer = setTimeout(() => abort.abort(), timeoutMs);
  const shell = [];
  let result = null;
  let error = null;
  try {
    const run = query({
      prompt,
      options: {
        model,
        cwd,
        abortController: abort,
        permissionMode: "bypassPermissions",
        allowDangerouslySkipPermissions: true,
        // Claude Code's own prompt and tools, as a user's session has them.
        systemPrompt: { type: "preset", preset: "claude_code" },
        settingSources: [],
        // The installed Claude Code: the SDK's bundled one can be older than a model requires
        // (Opus 5.5 needs 2.1.280+, the SDK bundled 2.1.81 and every run got a 400).
        pathToClaudeCodeExecutable: guardedClaude(home, own),
        mcpServers: { cmux: { type: "stdio", ...mcp } },
        effort,
        env: { ...env, CLAUDE_CONFIG_DIR: home, ...(allTools ? { ENABLE_TOOL_SEARCH: "true" } : {}) },
        stderr: () => {},
      },
    });
    for await (const message of run) {
      if (message.type === "assistant") {
        for (const block of message.message?.content ?? []) {
          if (block.type === "tool_use" && block.name === "Bash") shell.push(String(block.input?.command ?? ""));
        }
      }
      if (message.type === "result") result = message;
    }
  } catch (e) {
    error = String(e?.message ?? e);
  } finally {
    clearTimeout(timer);
  }
  const u = result?.usage ?? {};
  return {
    text: result?.result ?? "",
    steps: Math.max(0, (result?.num_turns ?? 1) - 1),
    usage: { input: u.input_tokens ?? 0, output: u.output_tokens ?? 0, cacheRead: u.cache_read_input_tokens ?? 0, cacheWrite: u.cache_creation_input_tokens ?? 0, cost: result?.total_cost_usd ?? 0 },
    shell,
    error: result
      ? result.is_error || /^API Error: [45]\d\d/.test(String(result.result ?? ""))
        ? `result error: ${String(result.result ?? result.subtype).slice(0, 300)}`
        : null
      : (error ?? "no result"),
  };
}

const tomlString = (value) => JSON.stringify(String(value));

/** A clean CODEX_HOME: the model route and login of this machine's config, nothing else. */
export function codexHome(home) {
  mkdirSync(home, { recursive: true });
  const config = readFileSync(join(homedir(), ".codex/config.toml"), "utf8");
  const top = config.split("\n[")[0].split("\n").filter((l) => /^(openai_base_url|model_provider|service_tier)\s*=/.test(l));
  const providers = [...config.matchAll(/\n\[model_providers\.[^\]]+\][\s\S]*?(?=\n\[|$)/g)].map((m) => m[0]);
  writeFileSync(join(home, "config.toml"), `${top.join("\n")}\napproval_policy = "never"\nsandbox_mode = "danger-full-access"\nnotify = []\n${providers.join("\n")}\n`);
  copyFileSync(join(homedir(), ".codex/auth.json"), join(home, "auth.json"));
  return home;
}

/**
 * One Codex turn through `codex app-server`: initialize, thread/start with the cmux MCP
 * server in its config, turn/start, then read notifications until turn/completed.
 */
export async function runCodexAppServer({ model, prompt, cwd, mcp, env, home, own, effort, timeoutMs }) {
  codexHome(home);
  const mcpConfig = [
    `mcp_servers.cmux.command=${tomlString(mcp.command)}`,
    `mcp_servers.cmux.args=[${mcp.args.map(tomlString).join(",")}]`,
    `mcp_servers.cmux.env={${Object.entries(mcp.env).map(([k, v]) => `${k}=${tomlString(v)}`).join(",")}}`,
  ].flatMap((c) => ["-c", c]);
  // A scratch HOME too: Codex reads ~/.agents/skills, which holds this machine's own skills.
  const scratchHome = join(home, "home");
  mkdirSync(scratchHome, { recursive: true });
  const child = spawn(...guarded(home, own, "codex", ["app-server", ...mcpConfig]), {
    cwd, env: { ...env, HOME: scratchHome, CODEX_HOME: home }, stdio: ["pipe", "pipe", "pipe"],
  });
  let next = 1;
  const waiting = new Map();
  const shell = [];
  let text = "";
  let steps = 0;
  let usage = {};
  let done;
  const finished = new Promise((resolve) => { done = resolve; });
  const send = (msg) => child.stdin.write(`${JSON.stringify(msg)}\n`);
  const request = (method, params) => {
    const id = next++;
    send({ jsonrpc: "2.0", id, method, params });
    return new Promise((resolve, reject) => waiting.set(id, { resolve, reject }));
  };
  let buf = "";
  child.stdout.on("data", (chunk) => {
    buf += chunk;
    for (let i; (i = buf.indexOf("\n")) >= 0; ) {
      const line = buf.slice(0, i);
      buf = buf.slice(i + 1);
      let msg;
      try { msg = JSON.parse(line); } catch { continue; }
      if (msg.id !== undefined && waiting.has(msg.id) && !msg.method) {
        const w = waiting.get(msg.id);
        waiting.delete(msg.id);
        msg.error ? w.reject(new Error(msg.error.message)) : w.resolve(msg.result);
      } else if (msg.id !== undefined && msg.method) {
        // A server request (an approval): approve, as a full-access chat does. v2 item
        // approvals answer `accept`; the v1 exec and patch approvals `approved`.
        const decision = msg.method.startsWith("item/") ? "accept" : "approved";
        send({ jsonrpc: "2.0", id: msg.id, result: { decision } });
      } else if (msg.method === "item/completed") {
        const item = msg.params?.item ?? {};
        if (item.type === "commandExecution") shell.push(String(item.command ?? ""));
        if (item.type === "agentMessage") text += `${item.text ?? ""}\n`;
        if (!["agentMessage", "reasoning", "userMessage"].includes(item.type)) steps++;
      } else if (msg.method === "thread/tokenUsage/updated") {
        usage = msg.params?.tokenUsage?.total ?? msg.params?.tokenUsage ?? usage;
      } else if (msg.method === "turn/completed") {
        done(msg.params?.turn);
      } else if (msg.method === "error") {
        done({ error: msg.params });
      }
    }
  });
  let stderr = "";
  child.stderr.on("data", (c) => { stderr += c; });
  const timer = setTimeout(() => done({ error: { message: "timeout" } }), timeoutMs);
  let turn = null;
  let error = null;
  try {
    await request("initialize", { clientInfo: { name: "cmux-tool-evals", version: "1" } });
    send({ jsonrpc: "2.0", method: "initialized" });
    const started = await request("thread/start", { model, cwd, approvalPolicy: "never", sandbox: "danger-full-access", ephemeral: true });
    const threadId = started?.thread?.id ?? started?.threadId;
    await request("turn/start", { threadId, input: [{ type: "text", text: prompt }], effort });
    turn = await finished;
    if (turn?.error) error = String(turn.error.message ?? JSON.stringify(turn.error)).slice(0, 300);
    else if (turn?.status && turn.status !== "completed") error = `turn ${turn.status}: ${JSON.stringify(turn.error ?? "").slice(0, 200)}`;
  } catch (e) {
    error = `${String(e?.message ?? e)} ${stderr.slice(-300)}`;
  } finally {
    clearTimeout(timer);
    child.kill();
  }
  return {
    text: text.trim(),
    steps: Math.max(0, steps - 1),
    usage: { input: usage.inputTokens ?? 0, output: usage.outputTokens ?? 0, cacheRead: usage.cachedInputTokens ?? 0, cost: 0 },
    shell,
    error,
  };
}
