// The MCP servers Session Info's Connectors lists for a chat (ConnectorsSection.tsx, native
// connectors.ts) and `/mcp` names (cmuxCommands.ts `mcpCommandPlan`).
//
// A harness that reports its servers' state (Claude Code's system/init, acpmux `mcpServers`) gives
// each its state. A harness that reports none (Codex, every ACP harness) still starts with the
// servers acpmux gave it (acpmux `tools`, rows `mcp:<server>`): those list as on or off for the chat,
// never as connected, which nobody said. A server the chat turned off is not in `mcpServers` (Claude
// Code never loaded it), so it lists as off, where `/mcp enable` turns it on again.
import type { AcpmuxSnapshot } from "../model";

type McpServer = NonNullable<NonNullable<AcpmuxSnapshot["summary"]>["mcpServers"]>[number];

export type ConnectorServer = { name: string; status: McpServer["status"] | "on" | "off" };

export function connectorServers(
  summary: Pick<NonNullable<AcpmuxSnapshot["summary"]>, "mcpServers" | "tools"> | undefined,
): ConnectorServer[] {
  const reported: ConnectorServer[] = summary?.mcpServers ?? [];
  const named = new Set(reported.map((server) => server.name));
  const started = (summary?.tools ?? []).flatMap((tool): ConnectorServer[] => {
    const name = tool.id.startsWith("mcp:") ? tool.id.slice(4) : "";
    if (!name || named.has(name)) return [];
    // With the harness's report in hand, an unreported server that is on is one it did not load:
    // it says nothing true about it, so only an off one (the chat's choice) is added.
    if (reported.length > 0 && tool.enabled) return [];
    named.add(name);
    return [{ name, status: tool.enabled ? "on" : "off" }];
  });
  return [...reported, ...started];
}

/// Servers Connectors counts as working: connected, or on where the harness reports no state.
export const workingConnectors = (servers: readonly ConnectorServer[]): number =>
  servers.filter((server) => server.status === "connected" || server.status === "on").length;
