// Settings > Accounts and Devices > Connectors: the rows the card draws from cmux-platform's
// `GET /v1/connectors` (ops.ts ConnectorsState). Pure: no host calls, no clock.
import type { ConnectorConnectionWire, ConnectorWire, ConnectorsState } from "./ops";

/** One connection the person can use: theirs, or one their team shared. */
export type ConnectedRow = {
  id: string;
  provider: string;
  name: string;
  /** The provider account's display name, when the provider named one. */
  account: string | null;
  /** `active`, `pending`, `needs_reauth` or `error`. */
  status: string;
  sharing: "private" | "team";
  mine: boolean;
  canDisconnect: boolean;
};

/** One provider the person can connect (or could, once this server sets it up). */
export type AvailableRow = {
  provider: string;
  name: string;
  /** False: this server cannot connect it yet; the row says so and offers no Connect. */
  configured: boolean;
};

export type ConnectorRows = { connected: ConnectedRow[]; available: AvailableRow[] };

/** English names for the providers cmux knows, when the platform sends none (proper names). */
const NAMES: Record<string, string> = {
  github: "GitHub",
  "google-drive": "Google Drive",
  gitlab: "GitLab",
  linear: "Linear",
  slack: "Slack",
  gmail: "Gmail",
  "google-calendar": "Google Calendar",
};

export function connectorName(connector: Pick<ConnectorWire, "provider" | "name">): string {
  return connector.name || NAMES[connector.provider] || connector.provider;
}

const live = (connection: ConnectorConnectionWire) =>
  connection.status !== "revoked" && connection.status !== "expired";

/** Connected first (attention first, then the platform's order), then every provider without a
 * working connection of the person's own. A provider the team shared still offers Connect: the
 * person may want their own account too. */
export function connectorRows(state: ConnectorsState | null): ConnectorRows {
  const connectors = state?.connectors ?? [];
  const connected: ConnectedRow[] = [];
  const available: AvailableRow[] = [];
  for (const connector of connectors) {
    const name = connectorName(connector);
    const connections = (connector.connections ?? []).filter(live);
    for (const connection of connections) {
      connected.push({
        id: connection.id,
        provider: connector.provider,
        name,
        account: connection.account?.name || null,
        status: connection.status,
        sharing: connection.sharing,
        mine: connection.mine,
        canDisconnect: connection.canDisconnect,
      });
    }
    // A connection of the person's own that needs signing in again offers Connect again.
    if (
      !connections.some(
        (connection) => connection.mine && (connection.status === "active" || connection.status === "pending"),
      )
    ) {
      available.push({
        provider: connector.provider,
        name,
        configured: connector.configured ?? connector.state !== "unavailable",
      });
    }
  }
  const attention = (row: ConnectedRow) => (row.status === "needs_reauth" || row.status === "error" ? 0 : 1);
  connected.sort((a, b) => attention(a) - attention(b));
  return { connected, available };
}

/** Whether any connection waits on the person in their browser (a Connect they started). */
export function connectorsPending(rows: ConnectorRows): boolean {
  return rows.connected.some((row) => row.status === "pending");
}
