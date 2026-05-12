import { z } from "zod";
import * as path from "node:path";
import * as fs from "node:fs/promises";
import * as os from "node:os";
import { createPatch } from "diff";
import type { Tool, ToolContext, ToolResult } from "../core/types";

export const fileEditTool: Tool = {
  name: "file_edit",
  description:
    "Replace exact text in a file. Fails if old_string is not unique unless replace_all is true.",
  inputSchema: z.object({
    path: z.string(),
    old_string: z.string(),
    new_string: z.string(),
    replace_all: z.boolean().optional(),
  }),
  defaultPermission: "ask",

  async run(
    input: unknown,
    ctx: ToolContext
  ): Promise<ToolResult> {
    const parsed = (
      fileEditTool.inputSchema as ReturnType<typeof z.object>
    ).parse(input) as {
      path: string;
      old_string: string;
      new_string: string;
      replace_all?: boolean;
    };

    ctx.log("debug", `file_edit: ${parsed.path}`);

    if (ctx.abortSignal.aborted) {
      return { content: "Aborted.", isError: true };
    }

    const resolved = path.isAbsolute(parsed.path)
      ? parsed.path
      : path.resolve(ctx.cwd, parsed.path);

    // Read the file
    const file = Bun.file(resolved);
    const exists = await file.exists();
    if (!exists) {
      return {
        content: `File not found: ${resolved}`,
        isError: true,
      };
    }

    const oldContent = await file.text();

    // Count occurrences
    let count = 0;
    let searchIdx = 0;
    while (true) {
      const idx = oldContent.indexOf(parsed.old_string, searchIdx);
      if (idx === -1) break;
      count++;
      searchIdx = idx + parsed.old_string.length;
    }

    if (count === 0) {
      return {
        content: `string not found in ${resolved}`,
        isError: true,
      };
    }

    if (count > 1 && !parsed.replace_all) {
      return {
        content: `string is not unique (${count} occurrences); pass replace_all:true or provide more context`,
        isError: true,
      };
    }

    if (ctx.abortSignal.aborted) {
      return { content: "Aborted.", isError: true };
    }

    // Perform replacement
    let newContent: string;
    if (parsed.replace_all) {
      newContent = oldContent.split(parsed.old_string).join(parsed.new_string);
    } else {
      // Replace the single occurrence
      const idx = oldContent.indexOf(parsed.old_string);
      newContent =
        oldContent.slice(0, idx) +
        parsed.new_string +
        oldContent.slice(idx + parsed.old_string.length);
    }

    // Atomic write
    const tmpPath = path.join(
      os.tmpdir(),
      `cmux101-edit-${Date.now()}-${Math.random().toString(36).slice(2)}.tmp`
    );

    try {
      await Bun.write(tmpPath, newContent);
      await fs.rename(tmpPath, resolved);
    } catch (err) {
      await fs.unlink(tmpPath).catch(() => {});
      return {
        content: `Failed to write file: ${String(err)}`,
        isError: true,
      };
    }

    // Generate unified diff
    const diff = createPatch(resolved, oldContent, newContent, "", "");

    return {
      content: diff,
    };
  },
};
