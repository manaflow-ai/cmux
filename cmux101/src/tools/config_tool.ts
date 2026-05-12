import { z } from "zod";
import type { Tool, ToolContext, ToolResult } from "../core/types.js";

export const configTool: Tool = {
  name: "config_read",
  description:
    "Return a JSON summary of the current session's runtime configuration: provider, model, cwd, permission mode, registered tool count, and cmux availability.",
  inputSchema: z.object({}),
  defaultPermission: "allow",

  async run(_input: unknown, ctx: ToolContext): Promise<ToolResult> {
    const { meta } = ctx.session;

    // Check cmux availability by probing for a known cmux tool
    const cmuxAvailable = ctx.toolRegistry.list().some((t) => t.name.startsWith("cmux_") || t.name.startsWith("pane_") || t.name.startsWith("workspace_"));

    const summary = {
      provider: meta.providerId,
      model: meta.model,
      cwd: meta.cwd,
      sessionId: meta.id,
      startedAt: meta.startedAt,
      permissionMode: ctx.permissions.resolve("*", null),
      registeredToolCount: ctx.toolRegistry.list().length,
      cmuxAvailable,
    };

    return { content: JSON.stringify(summary, null, 2) };
  },
};

export const configTools: Tool[] = [configTool];
