// The Inspector's Connectors: the MCP servers the chat's harness loaded, each with its state. A
// failed one says so, and where acpmux reconnects one (`_acpmux/mcp/reconnect`: a Claude Code chat)
// its Reconnect button asks Claude Code to connect it again; the row then reads connected when
// acpmux says so. Without that, "Needs reconnect" is plain text: nothing here looks clickable that
// is not.
import { useState } from "react";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import type { AcpmuxSnapshot } from "../model";

type McpServer = NonNullable<NonNullable<AcpmuxSnapshot["summary"]>["mcpServers"]>[number];

const ROW_ICON = rowIconSize(12);

export function ConnectorsSection({
  servers,
  onReconnect,
}: {
  servers: readonly McpServer[];
  /// `_acpmux/mcp/reconnect` of the server by its name.
  onReconnect?: (server: string) => Promise<unknown>;
}) {
  const t = useT();
  return (
    <ul className="acpmux-chat-inspector-list">
      {servers.map((server) => (
        <li key={server.name} className="acpmux-chat-inspector-row">
          <Icon name="extension" size={ROW_ICON} row />
          <span className="acpmux-chat-inspector-row__name">{server.name}</span>
          {server.status === "failed" && onReconnect ? (
            <ReconnectButton name={server.name} reconnect={onReconnect} />
          ) : (
            <span className="acpmux-chat-inspector-row__end" data-state={server.status}>
              {t(
                server.status === "failed"
                  ? "chatInspector.connectors.needsReconnect"
                  : server.status === "pending"
                    ? "rail.connectorPending"
                    : "composer.envConnected",
              )}
            </span>
          )}
        </li>
      ))}
    </ul>
  );
}

/// A failed server's Reconnect: busy while Claude Code tries, and after an error from acpmux it
/// reads Try again (in the danger color) and tries again. Success needs nothing here: acpmux marks
/// the server connected, and the row draws that instead of this button.
export function ReconnectButton({
  name,
  reconnect,
}: {
  name: string;
  reconnect: (server: string) => Promise<unknown>;
}) {
  const t = useT();
  const [state, setState] = useState<"idle" | "reconnecting" | "failed">("idle");
  const label = t(
    state === "reconnecting"
      ? "chatInspector.connectors.reconnecting"
      : state === "failed"
        ? "chatInspector.connectors.retry"
        : "chatInspector.connectors.reconnectAction",
  );
  return (
    <button
      type="button"
      className="acpmux-chat-inspector-link acpmux-chat-inspector-row__end"
      data-state={state}
      disabled={state === "reconnecting"}
      onClick={() => {
        setState("reconnecting");
        // A caller that hands back no promise (a spy) still settles the button.
        Promise.resolve(reconnect(name)).then(
          () => setState("idle"),
          () => setState("failed"),
        );
      }}
    >
      {label}
    </button>
  );
}
