/**
 * The subagent tool exposes `subagent_spawn` (single child) and
 * `subagent_spawn_many` (concurrent fan-out). It uses ctx.spawnSubagent
 * which the runner injects, so the tool itself is decoupled from the
 * dispatcher implementation.
 */

import { z } from "zod";
import type { Tool, ToolResult } from "../core/types.ts";

const spawnInput = z.object({
  label: z.string().min(1).describe("Short label for UI."),
  prompt: z.string().min(1).describe("Prompt sent to the subagent."),
  system: z.string().optional().describe("Optional system prompt override."),
  tools: z.array(z.string()).optional().describe("Whitelist of tool names; default = parent's full set."),
  model: z.string().optional().describe("Optional model override."),
  isolation: z.enum(["none", "worktree"]).optional().describe("If 'worktree', run inside a git worktree."),
});

export const subagentSpawnTool: Tool = {
  name: "subagent_spawn",
  description:
    "Spawn a subagent to investigate, research, or implement a focused task. " +
    "Returns the subagent's final text plus usage and transcript path.",
  inputSchema: spawnInput,
  defaultPermission: "allow",
  async run(input, ctx): Promise<ToolResult> {
    const parsed = spawnInput.parse(input);
    const result = await ctx.spawnSubagent({
      label: parsed.label,
      prompt: parsed.prompt,
      system: parsed.system,
      tools: parsed.tools,
      model: parsed.model,
      isolation: parsed.isolation,
    });
    const header = `[subagent ${parsed.label}] ok=${result.ok} tokens in/out=${result.usage.inputTokens}/${result.usage.outputTokens}`;
    return {
      content: `${header}\n\n${result.text}`,
      isError: !result.ok,
      data: result,
    };
  },
};

const spawnManyInput = z.object({
  agents: z
    .array(spawnInput)
    .min(1)
    .max(20)
    .describe("Up to 20 subagents to run concurrently."),
});

export const subagentSpawnManyTool: Tool = {
  name: "subagent_spawn_many",
  description:
    "Spawn multiple subagents in parallel. Returns the concatenated results, " +
    "one block per subagent.",
  inputSchema: spawnManyInput,
  defaultPermission: "allow",
  async run(input, ctx): Promise<ToolResult> {
    const parsed = spawnManyInput.parse(input);
    const results = await Promise.allSettled(
      parsed.agents.map((a) =>
        ctx.spawnSubagent({
          label: a.label,
          prompt: a.prompt,
          system: a.system,
          tools: a.tools,
          model: a.model,
          isolation: a.isolation,
        }),
      ),
    );
    let anyErr = false;
    const parts: string[] = [];
    for (let i = 0; i < results.length; i++) {
      const a = parsed.agents[i]!;
      const r = results[i]!;
      if (r.status === "fulfilled") {
        if (!r.value.ok) anyErr = true;
        parts.push(`=== ${a.label} (ok=${r.value.ok}) ===\n${r.value.text}`);
      } else {
        anyErr = true;
        parts.push(`=== ${a.label} (rejected) ===\n${String(r.reason)}`);
      }
    }
    return { content: parts.join("\n\n"), isError: anyErr };
  },
};

export const subagentTools: Tool[] = [subagentSpawnTool, subagentSpawnManyTool];
