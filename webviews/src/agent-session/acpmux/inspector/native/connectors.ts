// Session Info's Connectors, drawn by the App (ConnectorsSection.tsx): one row per MCP server the
// chat's harness loaded with its state; a failed one has Reconnect where acpmux reconnects one.
import type { AcpmuxSnapshot } from "../../model";
import type { Translate } from "../../i18n";
import type { NativeInfoActions, NativeInfoRow, NativeInfoSection, NativeInfoTone } from "./model";

type McpServer = NonNullable<NonNullable<AcpmuxSnapshot["summary"]>["mcpServers"]>[number];

export const CONNECTORS_SYMBOL = "puzzlepiece.extension";

const TONES: Record<McpServer["status"], NativeInfoTone> = { failed: "failed", connected: "done", pending: "waiting" };

export type ConnectorsInput = {
  /// `summary.mcpServers`.
  servers: readonly McpServer[];
  /// `_acpmux/mcp/reconnect` of the server by its name.
  onReconnect?: (server: string) => Promise<unknown>;
  /// The section is unfolded (`sections.connectors`).
  open: boolean;
  /// A Reconnect under way or failed, by server (ReconnectButton's own state, held by the caller).
  reconnecting?: Readonly<Record<string, "reconnecting" | "failed">>;
};

export function connectorsSection(
  input: ConnectorsInput,
  actions: NativeInfoActions,
  t: Translate,
): NativeInfoSection | undefined {
  const { servers, onReconnect } = input;
  if (servers.length === 0) return undefined;
  const reconnect = servers.filter((server) => server.status === "failed").length;
  const rows = servers.map((server): NativeInfoRow => {
    const row: NativeInfoRow = {
      id: server.name,
      symbol: CONNECTORS_SYMBOL,
      title: server.name,
      tone: TONES[server.status],
    };
    if (server.status === "failed" && onReconnect) {
      const state = input.reconnecting?.[server.name];
      return {
        ...row,
        buttons: [
          {
            label: t(
              state === "reconnecting"
                ? "chatInspector.connectors.reconnecting"
                : state === "failed"
                  ? "chatInspector.connectors.retry"
                  : "chatInspector.connectors.reconnectAction",
            ),
            disabled: state === "reconnecting",
            action: actions.add(`connectors.reconnect:${server.name}`, () => onReconnect(server.name)),
          },
        ],
      };
    }
    return {
      ...row,
      trailing: t(
        server.status === "failed"
          ? "chatInspector.connectors.needsReconnect"
          : server.status === "pending"
            ? "rail.connectorPending"
            : "composer.envConnected",
      ),
    };
  });
  return {
    id: "connectors",
    group: "about",
    title: t("rail.connectors"),
    symbol: CONNECTORS_SYMBOL,
    // As Claude Code desktop's: the servers to reconnect when any failed, else the connected ones.
    meta:
      reconnect > 0
        ? t("chatInspector.connectors.reconnect", { count: reconnect })
        : t("rail.connected", { count: servers.filter((server) => server.status === "connected").length }),
    open: input.open,
    foldable: true,
    rows,
  };
}
