import { createContext } from "react";
import type { PageClient } from "../../../pages/shared/pageClient";
import type { ChatWidgetTool } from "../../../apps/scene/chatWidgetClient";
import type { AcpmuxActivity } from "../model";
import { mcpCall } from "./mcpCalls";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

/** The page client widgets mount through; galleries and tests provide their own. */
export const ChatWidgetClientContext = createContext<PageClient | null | undefined>(undefined);

function parse(text: string | undefined): unknown {
  if (!text) return undefined;
  try {
    return JSON.parse(text);
  } catch {
    return undefined;
  }
}

/** The call as the daemon routes it: an MCP call by its `mcp__<server>__<tool>` name with its
 * arguments (Codex nests them; Claude Code passes them as the input), any other call by the name its
 * harness gave it. */
export function widgetTool(tool: Tool): ChatWidgetTool {
  const mcp = mcpCall(tool);
  const name = mcp
    ? `mcp__${mcp.server}__${mcp.tool}`
    : (tool.provenance?.claudeCodeToolName ?? tool.provenance?.claudeTool ?? tool.title).trim();
  const input = mcp ? mcp.args : parse(tool.inputSummary);
  return {
    name: name.slice(0, 128),
    ...(tool.title && { title: tool.title }),
    status: tool.status,
    ...(input !== undefined && { input }),
    ...(tool.output && { output: tool.output }),
  };
}
