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

/// `pendingSaid`: the pending servers whose start has lasted the shared bound (`pendingConnectors`,
/// `useConnectionQuietKeys`); one that comes up sooner counts as loaded, so a chat's open never
/// reads "2 connecting" for the second its harness starts its servers. Undefined: every one.
export function summarizeConnectors(
  servers: readonly { name?: string; status?: ConnectorStatus }[],
  pendingSaid?: ReadonlySet<string>,
): ConnectorSummary {
  const failed = servers.filter((server) => server.status === "failed").length;
  if (failed > 0) return { kind: "reconnect", count: failed };
  const pending = servers.filter(
    (server) => server.status === "pending" && (!pendingSaid || pendingSaid.has(server.name ?? "")),
  ).length;
  if (pending > 0) return { kind: "connecting", count: pending };
  return { kind: "loaded", count: servers.length };
}

/// The names of the servers still starting (`pending`), the keys `useConnectionQuietKeys` holds.
export const pendingConnectors = (servers: readonly { name: string; status?: ConnectorStatus }[]): string[] =>
  servers.filter((server) => server.status === "pending").map((server) => server.name);
