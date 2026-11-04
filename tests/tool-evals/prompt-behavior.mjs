#!/usr/bin/env node
// Fixed, synthetic repository tasks for prompt-guidance A/Bs. The model and
// captured Claude Code system/native tool schemas are real; file/command results
// are deterministic fixtures. No model-generated shell command is executed.
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { gunzipSync } from "node:zlib";
import { createHash } from "node:crypto";

const arg = (key, fallback) => {
  const i = process.argv.indexOf(`--${key}`);
  return i < 0 ? fallback : process.argv[i + 1];
};
const model = arg("model", "claude-sonnet-5-5");
const samples = Number(arg("samples", "3"));
const out = resolve(arg("out", process.env.FAST_CHECKS_OUT ?? "artifacts/prompt-behavior"));
const baseUrl = process.env.ANTHROPIC_BASE_URL ?? "http://localhost:4016";
const auth = process.env.ANTHROPIC_AUTH_TOKEN ?? process.env.ANTHROPIC_API_KEY ?? "";
const template = JSON.parse(gunzipSync(readFileSync(new URL("./templates/claude.json.gz", import.meta.url))));
// Freeze the pre-change arm: rebasing onto the shipped rule must not change it.
// Source: agent_tools.rs at 6dedb9cc163f68759c193491592b30950a78fe34.
const baseline = "Asking the person: the person allows tools through the chat's mode and the harness's own permission prompts, never through your questions, and a chat in Full access (Claude Code bypassPermissions, Codex full access) has already allowed every tool call its harness would ask about. So never ask them to allow, confirm or approve a step, with AskUserQuestion or in text (\"should I go ahead?\"): decide, say why in one line, and go on. Deciding never widens the task: a step a cmux skill keeps for the person's own request (importing a browser's cookies, deleting their data) waits for that request, and a cmux consent card is theirs to answer; leave such a step out and say so. Ask only about product taste you cannot settle from the request or the code, as that choice, never as a permission.";
const compact = "Asking the person: Full access already permits harness tool calls; never ask them to allow or confirm one. Decide, say why, continue. This never widens the task: respect user-only skill steps and consent cards; never bypass refusals. Ask only unresolved product taste, not permission.";
const guidance = "Read relevant instructions and likely source files early. Batch independent reads and searches into parallel tool calls; sequence dependent work. Start long-running builds, tests, and waits in the background when the tools support it, then continue useful independent work. Rejoin and inspect the results before relying on them. Keep reports concise: explain the outcome, verification, and remaining blockers.";
const arms = {
  baseline: { mcpInstructions: baseline, firstTurnContext: null },
  guidance: { mcpInstructions: compact, firstTurnContext: `<cmux-default-context>${guidance}</cmux-default-context>` },
};
// A refreshed capture must not silently duplicate either intervention.
const capturedText = JSON.stringify([template.system, template.reminders]);
if (/Asking the person:|<cmux-(?:default|user|project)-context>/i.test(capturedText) || capturedText.includes(guidance)) {
  throw new Error("Captured template already contains cmux guidance; isolate it before comparing arms");
}
const mcpBlock = (text) => ({ type: "text", text: `# MCP Server Instructions\n\nThe following MCP servers have provided instructions for how to use their tools and resources:\n\n## cmux\n${text}` });
const tools = template.tools.filter((t) => ["Read", "Bash"].includes(t.name));
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const tasks = [
  {
    id: "independent-configs",
    prompt: "What ports do the API, web and metrics services use? Read /repo/api.json, /repo/web.json and /repo/metrics.json, then give me the three service/port pairs.",
    files: { "api.json": '{"port":7319}', "web.json": '{"port":4287}', "metrics.json": '{"port":9563}' },
    must: ["7319", "4287", "9563"],
  },
  {
    id: "compare-contracts",
    prompt: "Check /repo/client.md, /repo/server.md and /repo/schema.md. Tell me which side disagrees with the schema and what field name to fix.",
    files: { "client.md": "The client sends the field retry_limit.", "server.md": "The server reads the field retries.", "schema.md": "The wire contract names this field retry_limit." },
    must: ["retries", "retry_limit"],
    mustPatterns: ["server[\\s\\S]{0,80}retries", "retries[\\s\\S]{0,80}retry_limit"],
  },
  {
    id: "test-and-changelog",
    prompt: "Run npm test and review /repo/CHANGELOG.md and /repo/package.json. Tell me the test result, the release version, and the change to mention in the release note.",
    files: { "CHANGELOG.md": "Next release: preserve draft text when moving a pane.", "package.json": '{"version":"3.8.27","scripts":{"test":"fixture-tests"}}' },
    command: "npm test", result: "17 tests passed; 0 failed. EVAL_TEST_DONE", must: ["17", "3.8.27", "draft"],
  },
];

async function sample(task, arm, index) {
  const started = Date.now();
  let firstRead = null;
  let backgroundTasks = 0;
  let job = null;
  const turns = [];
  const calls = [];
  const usage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 };
  const prompt = [{ type: "text", text: `${template.reminders.join("\n")}\nWorking directory: /repo\n\n${task.prompt}` }];
  // Match the product seam: cmux appends its block to the first user prompt.
  if (arms[arm].firstTurnContext) prompt.push({ type: "text", text: arms[arm].firstTurnContext });
  const messages = [{ role: "user", content: prompt }];
  const answer = async (call) => {
    const input = call.input ?? {};
    calls.push({ name: call.name, input, at_ms: Date.now() - started });
    if (call.name === "Read") {
      firstRead ??= Date.now() - started;
      const path = String(input.file_path ?? "").replace(/^\/repo\//, "");
      if (path === "test-output.txt" && job) return await job;
      await delay(250);
      if (Object.hasOwn(task.files, path)) return task.files[path];
      throw new Error(`Fixture file not found: ${input.file_path}`);
    }
    if (call.name === "Bash") {
      if (task.command && String(input.command).trim() === task.command) {
        job = delay(2000).then(() => task.result);
        if (input.run_in_background) {
          backgroundTasks++;
          return "Command running in background. Task id: fixture-test. Output file: /repo/test-output.txt. Read that file to collect the completed result.";
        }
        return await job;
      }
      // Reading command output is supported; other shell commands are never run.
      if (job && /^cat\s+\/repo\/test-output\.txt$/.test(input.command)) return await job;
      throw new Error("Only this task's test command is available; use Read for the named files.");
    }
    throw new Error(`Unsupported tool ${call.name}`);
  };
  let text = "";
  let error = null;
  let stopReason = null;
  let stoppedNaturally = false;
  try {
    for (let step = 0; step < 12; step++) {
      const res = await fetch(`${baseUrl}/v1/messages`, {
        method: "POST", signal: AbortSignal.timeout(300_000),
        headers: { "content-type": "application/json", "anthropic-version": "2023-06-01", authorization: `Bearer ${auth}`,
          "user-agent": "claude-cli/2.1.311 (external, sdk-cli)", "x-app": "cli" },
        body: JSON.stringify({ model, max_tokens: 4000, system: [...template.system, mcpBlock(arms[arm].mcpInstructions)],
          tools, messages, thinking: { type: "adaptive", display: "omitted" }, output_config: { effort: "medium" } }),
      });
      if (!res.ok) throw new Error(`model ${res.status}: ${(await res.text()).slice(0, 200)}`);
      const result = await res.json();
      stopReason = result.stop_reason ?? stopReason;
      const u = result.usage ?? {};
      usage.input += u.input_tokens ?? 0;
      usage.output += u.output_tokens ?? 0;
      usage.cacheRead += u.cache_read_input_tokens ?? 0;
      usage.cacheWrite += u.cache_creation_input_tokens ?? 0;
      messages.push({ role: "assistant", content: result.content });
      text += result.content.filter((b) => b.type === "text").map((b) => b.text).join("\n");
      const uses = result.content.filter((b) => b.type === "tool_use");
      if (!uses.length) { stoppedNaturally = true; break; }
      turns.push(uses.length);
      // Fixture reads and the one test are independent; execute their batches
      // concurrently, unlike the historical app-operation runner.
      const results = await Promise.all(uses.map(async (call) => {
        try { return { type: "tool_result", tool_use_id: call.id, content: await answer(call) }; }
        catch (e) { return { type: "tool_result", tool_use_id: call.id, content: String(e.message), is_error: true }; }
      }));
      messages.push({ role: "user", content: results });
    }
  } catch (e) { error = String(e.message); }
  // Drain even a command whose output the model forgot to collect.
  if (job) await job;
  const requiredFiles = Object.keys(task.files);
  const readFiles = calls.filter((c) => c.name === "Read").map((c) => String(c.input.file_path).replace(/^\/repo\//, ""));
  const sawOutput = !task.command || messages.some((m) => Array.isArray(m.content) && m.content.some((b) => b.type === "tool_result" && b.content === task.result));
  const mustPatterns = (task.mustPatterns ?? []).every((pattern) => new RegExp(pattern, "i").test(text));
  const pass = !error && requiredFiles.every((f) => readFiles.includes(f)) && sawOutput && task.must.every((s) => text.toLowerCase().includes(s.toLowerCase())) && mustPatterns;
  const row = { task: task.id, arm, sample: index, model, pass, error,
    wall_ms: Date.now() - started, first_read_ms: firstRead,
    stop_reason: stopReason, step_cap_hit: !error && !stoppedNaturally,
    tool_calls: turns.reduce((a, b) => a + b, 0), tool_turns: turns.length,
    parallel_tool_turns: turns.filter((n) => n > 1).length,
    parallel_share: turns.length ? turns.filter((n) => n > 1).length / turns.length : 0,
    background_tasks: backgroundTasks, usage, tokens: Object.values(usage).reduce((a, b) => a + b, 0) };
  const dir = join(out, arm, task.id, `s${index}`);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "transcript.json"), JSON.stringify({ messages, calls, text }, null, 2));
  writeFileSync(join(dir, "row.json"), JSON.stringify(row, null, 2));
  return row;
}

const median = (values) => {
  const sorted = values.filter((n) => n != null).sort((a, b) => a - b);
  return sorted.length ? (sorted[Math.floor((sorted.length - 1) / 2)] + sorted[Math.ceil((sorted.length - 1) / 2)]) / 2 : null;
};
async function main() {
  mkdirSync(out, { recursive: true });
  const manifest = { model, samples, base_url: baseUrl, tasks: tasks.map((t) => t.id), template_source: template.source,
    template_sha256: createHash("sha256").update(JSON.stringify(template)).digest("hex"),
    fixture_sha256: createHash("sha256").update(JSON.stringify(tasks)).digest("hex"),
    baseline_source: "cmux-tui/crates/acpmux/src/agent_tools.rs@6dedb9cc163f68759c193491592b30950a78fe34",
    arms: Object.fromEntries(Object.entries(arms).map(([arm, parts]) => [arm, Object.entries(parts).map(([source, text]) => ({
      source, channel: source === "mcpInstructions" ? "system (MCP instruction approximation)" : "first-user-prompt, last block",
      text, chars: text?.length ?? 0, estimated_tokens: Math.ceil((text?.length ?? 0) / 4), method: "chars/4 estimate",
      sha256: text == null ? null : createHash("sha256").update(text).digest("hex"),
    }))])),
    delivery: "Both arms approximate MCP initialization instructions as one labelled system block. The product first-turn user-context seam is implemented by cmux#34702 (https://github.com/manaflow-ai/cmux/pull/34702); only the candidate adds the exact cmux-default-context block after normal first-turn user content.",
    candidate_intervention: "The candidate is one combined intervention: it replaces the long asking rule with the compact rule and adds the early/concurrent-work block. This paired experiment cannot attribute any behavior difference to either text independently.",
    limitation: "Synthetic Claude-only deterministic tool fixtures with historical Claude Code 2.1.311 system and native Read/Bash schemas (2026-10-27). No live MCP initialization or complete current session context. Measures model behavior; not a live app or Codex-session result." };
  writeFileSync(join(out, "manifest.json"), JSON.stringify(manifest, null, 2));
  const rows = [];
  // Paired, alternating order avoids warming or time-of-run always favoring an arm.
  for (let i = 0; i < samples; i++) for (const task of tasks) {
    for (const arm of i % 2 ? ["guidance", "baseline"] : ["baseline", "guidance"]) {
      const row = await sample(task, arm, i);
      rows.push(row);
      writeFileSync(join(out, "results.jsonl"), rows.map((r) => JSON.stringify(r)).join("\n") + "\n");
      console.log(`${arm} ${task.id} s${i}: ${row.pass ? "pass" : "FAIL"} wall=${row.wall_ms}ms calls=${row.tool_calls}/${row.tool_turns} parallel=${row.parallel_share} tokens=${row.tokens}${row.error ? ` ${row.error}` : ""}`);
      if (row.error) throw new Error(row.error);
    }
  }
  const summary = Object.fromEntries(Object.keys(arms).map((arm) => {
    const rs = rows.filter((r) => r.arm === arm);
    return [arm, { success: `${rs.filter((r) => r.pass).length}/${rs.length}`,
      ...Object.fromEntries(["wall_ms", "first_read_ms", "tool_calls", "tool_turns", "parallel_share", "tokens"].map((key) => [`median_${key}`, median(rs.map((r) => r[key]))])),
      calls_per_tool_turn: rs.reduce((n, r) => n + r.tool_calls, 0) / rs.reduce((n, r) => n + r.tool_turns, 0),
      aggregate_parallel_share: rs.reduce((n, r) => n + r.parallel_tool_turns, 0) / rs.reduce((n, r) => n + r.tool_turns, 0),
      background_tasks: rs.reduce((n, r) => n + r.background_tasks, 0),
      step_cap_hits: rs.filter((r) => r.step_cap_hit).length,
      stop_reasons: Object.fromEntries([...new Set(rs.map((r) => r.stop_reason).filter(Boolean))].map((reason) => [reason, rs.filter((r) => r.stop_reason === reason).length])),
      usage: Object.fromEntries(Object.keys(rs[0].usage).map((key) => [key, rs.reduce((n, r) => n + r.usage[key], 0)])) }];
  }));
  writeFileSync(join(out, "summary.json"), JSON.stringify(summary, null, 2));
  console.log(JSON.stringify(summary, null, 2));
  if (rows.some((r) => !r.pass)) process.exitCode = 1;
}
await main();
