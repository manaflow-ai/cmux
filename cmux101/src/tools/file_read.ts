import { z } from "zod";
import * as path from "node:path";
import type { Tool, ToolContext, ToolResult } from "../core/types";

const MAX_BYTES = 1024 * 1024; // 1 MB
const TRUNCATE_LINES = 500;

function formatWithLineNumbers(lines: string[], startLine: number): string {
  return lines
    .map((line, i) => {
      const lineNum = String(startLine + i).padStart(6, " ");
      return `${lineNum}\t${line}`;
    })
    .join("\n");
}

export const fileReadTool: Tool = {
  name: "file_read",
  description:
    "Read a file from the filesystem. Supports byte offset and line limit for large files.",
  inputSchema: z.object({
    path: z.string(),
    offset: z.number().int().nonnegative().optional(),
    limit: z.number().int().positive().optional(),
  }),
  defaultPermission: "allow",

  async run(
    input: unknown,
    ctx: ToolContext
  ): Promise<ToolResult> {
    const parsed = (
      fileReadTool.inputSchema as ReturnType<typeof z.object>
    ).parse(input) as { path: string; offset?: number; limit?: number };

    ctx.log("debug", `file_read: ${parsed.path}`);

    // Resolve path
    const resolved = path.isAbsolute(parsed.path)
      ? parsed.path
      : path.resolve(ctx.cwd, parsed.path);

    // Permission check for paths outside cwd
    const cwdNorm = ctx.cwd.endsWith(path.sep) ? ctx.cwd : ctx.cwd + path.sep;
    const isOutside = !resolved.startsWith(cwdNorm) && resolved !== ctx.cwd;
    if (isOutside) {
      const level = ctx.permissions.resolve("file_read", input);
      if (level !== "allow") {
        return {
          content: `Permission denied: ${resolved} is outside the working directory.`,
          isError: true,
        };
      }
    }

    // Check abort
    if (ctx.abortSignal.aborted) {
      return { content: "Aborted.", isError: true };
    }

    // Read file
    const file = Bun.file(resolved);
    const exists = await file.exists();
    if (!exists) {
      return {
        content: `File not found: ${resolved}`,
        isError: true,
      };
    }

    const fileSize = file.size;
    const rawText = await file.text();
    const allLines = rawText.split("\n");

    // Determine effective offset and limit
    const offsetLines = parsed.offset ?? 0;
    let sliced = allLines.slice(offsetLines);

    let truncationNote = "";

    if (parsed.limit !== undefined) {
      sliced = sliced.slice(0, parsed.limit);
    } else if (fileSize > MAX_BYTES) {
      // Cap to first TRUNCATE_LINES from the offset
      if (sliced.length > TRUNCATE_LINES) {
        sliced = sliced.slice(0, TRUNCATE_LINES);
        truncationNote = `\n(truncated, file is ${fileSize} bytes)`;
      }
    }

    const formatted = formatWithLineNumbers(sliced, offsetLines + 1);
    return {
      content: formatted + truncationNote,
    };
  },
};
