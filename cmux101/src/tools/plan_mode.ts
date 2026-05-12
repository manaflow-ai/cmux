import { z } from "zod";
import type { Tool, ToolContext, ToolResult } from "../core/types.js";

// ----------------------------------------------------------------------------
// enter_plan_mode
// ----------------------------------------------------------------------------

export const enterPlanModeTool: Tool = {
  name: "enter_plan_mode",
  description:
    "Enter plan mode. While in plan mode only read-only tools are permitted. " +
    "Call exit_plan_mode to return to normal operation.",
  inputSchema: z.object({
    reason: z.string().optional(),
  }),
  defaultPermission: "allow",

  async run(input: unknown, ctx: ToolContext): Promise<ToolResult> {
    const parsed = (enterPlanModeTool.inputSchema as ReturnType<typeof z.object>).parse(
      input,
    ) as { reason?: string };

    await ctx.session.recordEvent({
      kind: "plan_mode",
      data: { on: true, reason: parsed.reason },
    });

    const suffix = parsed.reason ? ` Reason: ${parsed.reason}` : "";
    return {
      content:
        `Entered plan mode.${suffix} Read-only tools only until /exit-plan or exit_plan_mode is called.`,
    };
  },
};

// ----------------------------------------------------------------------------
// exit_plan_mode
// ----------------------------------------------------------------------------

export const exitPlanModeTool: Tool = {
  name: "exit_plan_mode",
  description: "Exit plan mode. Normal tool permissions are restored.",
  inputSchema: z.object({}),
  defaultPermission: "allow",

  async run(_input: unknown, ctx: ToolContext): Promise<ToolResult> {
    await ctx.session.recordEvent({
      kind: "plan_mode",
      data: { on: false },
    });

    return { content: "Exited plan mode. All tools are now available." };
  },
};

// ----------------------------------------------------------------------------
// Export
// ----------------------------------------------------------------------------

export const planModeTools: Tool[] = [enterPlanModeTool, exitPlanModeTool];
