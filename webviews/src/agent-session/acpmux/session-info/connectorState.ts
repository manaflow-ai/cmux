/**
 * Session Info's connector summary describes the harness inventory, not provider auth.
 * MCP rows come from the attached session's `mcpServers`; a connected row means the harness
 * loaded its server. It does not prove that the provider account or selected resource is usable.
 */
export type ConnectorStatus = "connected" | "pending" | "failed" | string;

export type ConnectorSummary =
  | { kind: "reconnect"; count: number }
  | { kind: "connecting"; count: number }
  | { kind: "loaded"; count: number };

export function summarizeConnectors(servers: readonly { status?: ConnectorStatus }[]): ConnectorSummary {
  const failed = servers.filter((server) => server.status === "failed").length;
  if (failed > 0) return { kind: "reconnect", count: failed };
  const pending = servers.filter((server) => server.status === "pending").length;
  if (pending > 0) return { kind: "connecting", count: pending };
  return { kind: "loaded", count: servers.length };
}
