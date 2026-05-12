/**
 * grep tool — search file contents using ripgrep or a Node fallback.
 */

import { z } from "zod";
import { readFile } from "fs/promises";
import fg from "fast-glob";
import type { Tool, ToolContext, ToolResult } from "../core/types";

const DEFAULT_MAX_RESULTS = 200;
const HARD_MAX_RESULTS = 2000;

const inputSchema = z.object({
  pattern: z.string(),
  path: z.string().optional(),
  include: z.string().optional(),
  case_insensitive: z.boolean().optional(),
  max_results: z.number().int().positive().optional(),
});

type GrepInput = z.infer<typeof inputSchema>;

interface GrepMatch {
  file: string;
  line: number;
  content: string;
}

/** Run rg and parse JSON-line output */
async function runRipgrep(
  rgPath: string,
  input: GrepInput,
  cwd: string,
  maxResults: number,
): Promise<GrepMatch[]> {
  const args: string[] = [
    "--line-number",
    "--no-heading",
    "--color=never",
  ];

  if (input.case_insensitive) args.push("-i");
  if (input.include) args.push("--glob", input.include);
  if (maxResults > 0) args.push("--max-count", "1"); // per-file; we'll cap total below

  args.push(input.pattern);

  if (input.path) {
    args.push(input.path);
  }

  const proc = Bun.spawn([rgPath, ...args], {
    cwd,
    stdout: "pipe",
    stderr: "pipe",
  });

  const [stdoutBuf] = await Promise.all([
    new Response(proc.stdout).text(),
    proc.exited,
  ]);

  const matches: GrepMatch[] = [];
  for (const line of stdoutBuf.split("\n")) {
    if (!line.trim()) continue;
    // Format: filename:linenum:content
    const firstColon = line.indexOf(":");
    if (firstColon === -1) continue;
    const secondColon = line.indexOf(":", firstColon + 1);
    if (secondColon === -1) continue;
    const file = line.slice(0, firstColon);
    const lineNum = parseInt(line.slice(firstColon + 1, secondColon), 10);
    const content = line.slice(secondColon + 1);
    if (!isNaN(lineNum)) {
      matches.push({ file, line: lineNum, content });
      if (matches.length >= maxResults) break;
    }
  }

  return matches;
}

/** JS fallback: glob files, search lines */
async function runJsFallback(
  input: GrepInput,
  cwd: string,
  maxResults: number,
): Promise<GrepMatch[]> {
  const globPattern = input.path ?? (input.include ?? "**/*");
  const files = await fg(globPattern, {
    cwd,
    ignore: ["**/node_modules/**", "**/.git/**", "**/dist/**", "**/build/**"],
    onlyFiles: true,
    absolute: false,
    dot: true,
  });

  const flags = input.case_insensitive ? "gi" : "g";
  let regex: RegExp;
  try {
    regex = new RegExp(input.pattern, flags);
  } catch {
    return [];
  }

  const matches: GrepMatch[] = [];

  for (const file of files) {
    if (matches.length >= maxResults) break;
    let text: string;
    try {
      text = await readFile(`${cwd}/${file}`, "utf8");
    } catch {
      continue;
    }
    const lines = text.split("\n");
    for (let i = 0; i < lines.length; i++) {
      regex.lastIndex = 0;
      if (regex.test(lines[i])) {
        matches.push({ file, line: i + 1, content: lines[i] });
        if (matches.length >= maxResults) break;
      }
    }
  }

  return matches;
}

async function runGrep(input: GrepInput, ctx: ToolContext): Promise<ToolResult> {
  const cwd = input.path
    ? ctx.cwd // rg will handle path relative to cwd
    : ctx.cwd;

  const maxResults = Math.min(
    input.max_results ?? DEFAULT_MAX_RESULTS,
    HARD_MAX_RESULTS,
  );

  let matches: GrepMatch[];

  const rgPath = Bun.which("rg");
  if (rgPath) {
    matches = await runRipgrep(rgPath, input, cwd, maxResults);
  } else {
    matches = await runJsFallback(input, cwd, maxResults);
  }

  if (matches.length === 0) {
    return { content: "No matches found." };
  }

  const lines = matches.map((m) => `${m.file}:${m.line}:${m.content}`);
  return { content: lines.join("\n") };
}

export const grepTool: Tool = {
  name: "grep",
  description:
    "Search file contents using ripgrep (preferred) or a Node fallback. Returns file:line:matched-content.",
  inputSchema,
  defaultPermission: "allow",
  run(input: unknown, ctx: ToolContext): Promise<ToolResult> {
    const parsed = inputSchema.parse(input);
    return runGrep(parsed, ctx);
  },
};
