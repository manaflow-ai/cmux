// How many of the agents' real forum shell commands draw as forum rows when Settings > Customize >
// Forum Tool Calls is on, and what parsing one costs. Reads Claude Code transcripts (JSONL, the
// arguments or every *.jsonl under ~/.claude/projects) and takes each shell command naming agent-forum.
// Usage: bun scripts/measure-forum-shell-calls.ts [TRANSCRIPT.jsonl ...]
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { forumCommand } from "../src/agent-session/acpmux/conversation/forumShellCalls";

function transcripts(): string[] {
  if (process.argv.length > 2) return process.argv.slice(2);
  const root = path.join(os.homedir(), ".claude/projects");
  if (!fs.existsSync(root)) return [];
  return fs
    .readdirSync(root, { recursive: true, encoding: "utf8" })
    .filter((name) => name.endsWith(".jsonl"))
    .map((name) => path.join(root, name));
}

const commands: string[] = [];
for (const file of transcripts()) {
  for (const line of fs.readFileSync(file, "utf8").split("\n")) {
    if (!line.includes("agent-forum")) continue;
    let row: unknown;
    try {
      row = JSON.parse(line);
    } catch {
      continue;
    }
    const content = (row as { message?: { content?: unknown } }).message?.content;
    if (!Array.isArray(content)) continue;
    for (const part of content as { type?: string; name?: string; input?: { command?: unknown } }[]) {
      const command = part.type === "tool_use" && part.name === "Bash" ? part.input?.command : undefined;
      if (typeof command === "string" && /\bagent-forum\b/.test(command)) commands.push(command);
    }
  }
}

const by: Record<string, number> = {};
let drawn = 0;
for (const command of commands) {
  const parsed = forumCommand(command);
  if (!parsed) continue;
  drawn++;
  by[parsed.action] = (by[parsed.action] ?? 0) + 1;
}
const rounds = 100;
const start = performance.now();
for (let i = 0; i < rounds; i++) for (const command of commands) forumCommand(command);
const perCall = commands.length ? ((performance.now() - start) * 1000) / (rounds * commands.length) : 0;
console.log(JSON.stringify({ commands: commands.length, drawn, by, parseMicros: Number(perCall.toFixed(2)) }));
