import { z } from "zod";
import * as path from "node:path";
import * as fs from "node:fs/promises";
import * as os from "node:os";
import type { Tool, ToolContext, ToolResult } from "../core/types";

export const fileWriteTool: Tool = {
  name: "file_write",
  description:
    "Write content to a file, creating it or overwriting if exists. Use file_edit for partial changes.",
  inputSchema: z.object({
    path: z.string(),
    content: z.string(),
  }),
  defaultPermission: "ask",

  async run(
    input: unknown,
    ctx: ToolContext
  ): Promise<ToolResult> {
    const parsed = (
      fileWriteTool.inputSchema as ReturnType<typeof z.object>
    ).parse(input) as { path: string; content: string };

    ctx.log("debug", `file_write: ${parsed.path}`);

    if (ctx.abortSignal.aborted) {
      return { content: "Aborted.", isError: true };
    }

    const resolved = path.isAbsolute(parsed.path)
      ? parsed.path
      : path.resolve(ctx.cwd, parsed.path);

    // Create parent directories if missing
    const parentDir = path.dirname(resolved);
    await fs.mkdir(parentDir, { recursive: true });

    if (ctx.abortSignal.aborted) {
      return { content: "Aborted.", isError: true };
    }

    // Atomic write: write to tmp, then rename
    const tmpPath = path.join(
      os.tmpdir(),
      `cmux101-write-${Date.now()}-${Math.random().toString(36).slice(2)}.tmp`
    );

    try {
      await Bun.write(tmpPath, parsed.content);
      await fs.rename(tmpPath, resolved);
    } catch (err) {
      // Clean up tmp on failure
      await fs.unlink(tmpPath).catch(() => {});
      return {
        content: `Failed to write file: ${String(err)}`,
        isError: true,
      };
    }

    const byteLength = Buffer.byteLength(parsed.content, "utf8");
    return {
      content: `Wrote ${byteLength} bytes to ${resolved}`,
    };
  },
};
