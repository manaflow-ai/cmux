#!/usr/bin/env bun
// Turns one captured Claude Code request (`/v1/messages` body, cmux MCP connected) into
// templates/claude.json.gz: the harness prompt and native tools, with placeholders where
// run.mjs puts this checkout's cmux text. Removes the user's memory, skills, home paths and
// ids. Usage: bun trim-capture.mjs <capture.json> templates/claude.json.gz
import { readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { gzipSync } from "node:zlib";

const [input, output] = process.argv.slice(2);
const req = JSON.parse(readFileSync(input, "utf8"));
const home = homedir();
const scrub = (s) => s.replaceAll(home, "/home/user").replace(/\/Users\/[\w.-]+/g, "/home/user");

// Native tools a stock Claude Code turn has; user-installed ones (Workflow, mods) are dropped.
const KEEP = new Set(["Agent", "Bash", "Edit", "Read", "Write", "ToolSearch"]);
const tools = req.tools.filter((t) => KEEP.has(t.name)).map((t) => JSON.parse(scrub(JSON.stringify(t))));

const system = req.system
  .filter((b) => !b.text.startsWith("x-anthropic-billing-header"))
  .map((b) => ({ ...b, text: scrub(b.text.replace(/\n# Memory\n[\s\S]*?(?=\n# [A-Z]|$)/, "\n")) }));

const reminders = req.messages[0].content.slice(0, -1).map((b) => b.text);

const envMessage = req.messages.find((m) => m.role === "system");
let env = envMessage.content[0].text;
const deferredBlock = /(The following deferred tools are now available via ToolSearch\.[^\n]*\n)((?:[^\n]+\n)*)/;
const deferred = env.match(deferredBlock)[2].split("\n").filter((n) => n && !n.startsWith("mcp__"));
env = env
  .replace(deferredBlock, "$1{{DEFERRED}}\n")
  .replace(/# MCP Server Instructions\n[\s\S]*?(?=The following skills|\n# |Today's date)/, "{{MCP_INSTRUCTIONS}}")
  .replace(/The following skills are available for use with the Skill tool:\n[\s\S]*?(?=\n\nToday's date|\n# )/, "")
  .replace(/Primary working directory: \S+/, "Primary working directory: {{CWD}}")
  .replace(/ - Additional working directories:\n(\s+- .*\n)*/, "")
  .replace(/You are powered by the model named .+?\. The exact model ID is [\w.-]+\./, "You are powered by the model {{MODEL}}.");
env = scrub(env);

const template = { source: "Claude Code 2.1.311 turn, cmux mcp serve connected, captured 2026-10-27", system, tools, reminders, env, deferred };
const leaks = JSON.stringify(template).match(/\/Users\/|device_id|account_uuid/g);
if (leaks) throw new Error(`template still has private data: ${[...new Set(leaks)].join(", ")}`);
writeFileSync(output, gzipSync(JSON.stringify(template)));
console.log(`wrote ${output}: ${tools.length} tools, ${deferred.length} deferred, env ${env.length} chars`);
