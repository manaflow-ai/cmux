import { z } from "zod";
import type { Tool, ToolContext, ToolResult } from "../core/types.js";

const MAX_SECONDS = 600;

export const sleepTool: Tool = {
  name: "sleep",
  description: `Wait for the specified number of seconds (max ${MAX_SECONDS}). Useful when waiting for background tasks to complete.`,
  inputSchema: z.object({
    seconds: z.number().min(0).max(MAX_SECONDS),
  }),
  defaultPermission: "allow",

  async run(input: unknown, ctx: ToolContext): Promise<ToolResult> {
    const parsed = (sleepTool.inputSchema as ReturnType<typeof z.object>).parse(input) as {
      seconds: number;
    };

    const ms = Math.round(parsed.seconds * 1000);

    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(resolve, ms);

      if (ctx.abortSignal.aborted) {
        clearTimeout(timer);
        reject(new Error("Aborted"));
        return;
      }

      ctx.abortSignal.addEventListener("abort", () => {
        clearTimeout(timer);
        reject(new Error("Aborted"));
      });
    });

    return { content: `Slept for ${parsed.seconds} seconds.` };
  },
};

export const sleepTools: Tool[] = [sleepTool];
