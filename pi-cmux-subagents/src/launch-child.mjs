import { spawn } from "node:child_process";
import { readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";

const runDirectory = process.argv[2];
if (!runDirectory) throw new Error("missing run directory");

const config = JSON.parse(await readFile(join(runDirectory, "config.json"), "utf8"));
const rolePrompts = {
  Explore: "You are a fast, read-only code explorer. Locate evidence precisely and do not modify files.",
  Plan: "You are a read-only software architect. Inspect the repository and return an actionable implementation plan.",
  reviewer: "You are a disciplined reviewer. Inspect the requested code or plan, report only evidence-backed findings, and do not modify files.",
  worker: "You are an implementation agent. Make the smallest correct change, verify it, and report changed files, checks, and residual risks.",
  "general-purpose": "You are a focused autonomous subagent. Complete the assigned task and return a concise, evidence-backed handoff.",
};
const readOnly = new Set(["Explore", "Plan", "reviewer"]);
const tools = readOnly.has(config.agentType)
  ? "read,bash,grep,find,ls,report_to_parent"
  : "read,bash,grep,find,ls,edit,write,report_to_parent";
const prompt = `${config.task}\n\nWhen finished or blocked, call report_to_parent with the complete handoff.`;
const args = [
  "--name", `${config.agentType}: ${config.description}`,
  "--no-extensions",
  "--extension", config.childExtensionPath,
  "--tools", tools,
  "--append-system-prompt", rolePrompts[config.agentType] ?? rolePrompts["general-purpose"],
];
if (config.model) args.push("--model", config.model);
if (config.thinking) args.push("--thinking", config.thinking);
args.push(prompt);

const child = spawn("pi", args, {
  cwd: config.cwd,
  stdio: "inherit",
  env: {
    ...process.env,
    PI_CMUX_SUBAGENT_ID: config.id,
    PI_CMUX_SUBAGENT_RESULT: config.resultPath,
  },
});

child.on("exit", async (code, signal) => {
  try {
    await readFile(config.resultPath, "utf8");
  } catch {
    await writeFile(config.resultPath, `${JSON.stringify({
      id: config.id,
      status: "failed",
      error: signal ? `pi terminated by ${signal}` : `pi exited with code ${code ?? "unknown"}`,
      finishedAt: new Date().toISOString(),
    }, null, 2)}\n`, "utf8");
  }
  process.exit(code ?? (signal ? 1 : 0));
});

child.on("error", async (error) => {
  await writeFile(config.resultPath, `${JSON.stringify({
    id: config.id,
    status: "failed",
    error: error.message,
    finishedAt: new Date().toISOString(),
  }, null, 2)}\n`, "utf8");
  process.exit(1);
});
