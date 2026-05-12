/**
 * glob tool — find files matching a glob pattern.
 */

import { z } from "zod";
import fg from "fast-glob";
import { stat } from "fs/promises";
import type { Tool, ToolContext, ToolResult } from "../core/types";

const MAX_RESULTS = 1000;

const IGNORED_DIRS = [
  "**/node_modules/**",
  "**/.git/**",
  "**/dist/**",
  "**/build/**",
  "**/.next/**",
  "**/__pycache__/**",
];

const inputSchema = z.object({
  pattern: z.string(),
  cwd: z.string().optional(),
});

type GlobInput = z.infer<typeof inputSchema>;

async function runGlob(input: GlobInput, ctx: ToolContext): Promise<ToolResult> {
  const cwd = input.cwd ?? ctx.cwd;

  const paths = await fg(input.pattern, {
    cwd,
    ignore: IGNORED_DIRS,
    onlyFiles: false,
    absolute: false,
    dot: true,
  });

  // Sort by mtime descending
  const withMtime: Array<{ path: string; mtime: number }> = await Promise.all(
    paths.map(async (p) => {
      try {
        const s = await stat(`${cwd}/${p}`);
        return { path: p, mtime: s.mtimeMs };
      } catch {
        return { path: p, mtime: 0 };
      }
    }),
  );

  withMtime.sort((a, b) => b.mtime - a.mtime);

  const capped = withMtime.slice(0, MAX_RESULTS);
  const resultPaths = capped.map((x) => x.path);

  const header = `Found ${resultPaths.length} matches:`;
  const content = resultPaths.length > 0
    ? `${header}\n${resultPaths.join("\n")}`
    : header;

  return { content };
}

export const globTool: Tool = {
  name: "glob",
  description:
    "Find files matching a glob pattern. Returns up to 1000 paths sorted by modification time (newest first).",
  inputSchema,
  defaultPermission: "allow",
  run(input: unknown, ctx: ToolContext): Promise<ToolResult> {
    const parsed = inputSchema.parse(input);
    return runGlob(parsed, ctx);
  },
};
