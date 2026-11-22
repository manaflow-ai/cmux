/**
 * Session Info's connector summary describes the harness inventory, not provider auth.
 * MCP rows come from the attached session's `mcpServers`; a connected row means the harness
 * loaded its server. It does not prove that the provider account or selected resource is usable.
 */
import type { ConnectionQuietKeys } from "../../../ui/lasting";

export type ConnectorStatus = "connected" | "pending" | "failed" | string;

export type ConnectorSummary =
  | { kind: "reconnect"; count: number }
  | { kind: "connecting"; count: number }
  | { kind: "loaded"; count: number };

/// The key a server's connect waits under (``connectingShown``), the same on every surface.
export const connectorQuietKey = (name: string) => `mcp:${name}`;

/// Whether a server's row says it is still connecting. A connect heals on its own and offers nothing
/// to do, so it waits out the shared bound (`connectionQuiet`: the drawing component's
/// `useConnectionQuietKeys`, ui/lasting.ts) and the row says nothing of its state meanwhile (Leo,
/// 2026-11-14: "i also want all our connectivity stuff to shut up"). Every draw asks, pending or not.
export function connectingShown(
  server: { name: string; status?: ConnectorStatus },
  connectionQuiet: ConnectionQuietKeys,
): boolean {
  return connectionQuiet(connectorQuietKey(server.name), server.status === "pending");
}

/// The section's summary: failed ones at once (each offers Reconnect), connecting ones only once
/// their connect has lasted the bound (``connectingShown``), else the count loaded.
export function summarizeConnectors(
  servers: readonly { name: string; status?: ConnectorStatus }[],
  connectionQuiet: ConnectionQuietKeys,
): ConnectorSummary {
  const failed = servers.filter((server) => server.status === "failed").length;
  const pending = servers.filter((server) => connectingShown(server, connectionQuiet)).length;
  if (failed > 0) return { kind: "reconnect", count: failed };
  if (pending > 0) return { kind: "connecting", count: pending };
  return { kind: "loaded", count: servers.length };
}
