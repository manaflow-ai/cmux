#!/usr/bin/env bun
// Sits between a real agent CLI and `cmux mcp serve`: passes every JSON-RPC line through
// unchanged and appends {dir, msg} to the log, so a CLI run is graded on what it called.
// Usage: mcp-log.mjs <log.jsonl> <cmux> [serve args...]
import { spawn } from "node:child_process";
import { appendFileSync } from "node:fs";

const [log, cli, ...args] = process.argv.slice(2);
const child = spawn(cli, ["mcp", "serve", ...args], { stdio: ["pipe", "pipe", "inherit"] });
const relay = (from, to, dir) => {
  let buf = "";
  from.on("data", (chunk) => {
    to.write(chunk);
    buf += chunk;
    for (let i; (i = buf.indexOf("\n")) >= 0; ) {
      const line = buf.slice(0, i);
      buf = buf.slice(i + 1);
      if (!line.trim()) continue;
      try { appendFileSync(log, `${JSON.stringify({ dir, msg: JSON.parse(line) })}\n`); } catch {}
    }
  });
};
relay(process.stdin, child.stdin, "in");
relay(child.stdout, process.stdout, "out");
process.stdin.on("end", () => child.stdin.end());
child.on("exit", (code) => process.exit(code ?? 0));
