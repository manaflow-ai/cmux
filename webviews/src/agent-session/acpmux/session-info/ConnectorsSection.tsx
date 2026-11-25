// Session Info's Connectors: the MCP servers the chat's harness loaded, each with its state. A
// failed one says so, and where acpmux reconnects one (`_acpmux/mcp/reconnect`: a Claude Code chat)
// its Reconnect button asks Claude Code to connect it again; the row then reads connected when
// acpmux says so. Without that, "Needs reconnect" is plain text: nothing here looks clickable that
// is not.
import { useState } from "react";
import { useConnectionQuiet } from "../../../ui/lasting";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import type { AcpmuxSnapshot } from "../model";
import { IMessageConnector } from "./IMessageConnector";
import type { IMessageView } from "./imessage";

type McpServer = NonNullable<NonNullable<AcpmuxSnapshot["summary"]>["mcpServers"]>[number];

const ROW_ICON = rowIconSize(12);

export function ConnectorsSection({
  servers,
  onReconnect,
  imessage,
}: {
  servers: readonly McpServer[];
  /// `_acpmux/mcp/reconnect` of the server by its name.
  onReconnect?: (server: string) => Promise<unknown>;
  imessage?: IMessageView;
}) {
  const t = useT();
  return (
    <ul className="acpmux-session-info-list">
      {imessage && <IMessageConnector view={imessage} />}
      {servers.map((server) => (
        <li key={server.name} className="acpmux-session-info-row">
          <Icon name="extension" size={ROW_ICON} row />
          <span className="acpmux-session-info-row__name">{server.name}</span>
          {server.status === "failed" && onReconnect ? (
            <ReconnectButton name={server.name} reconnect={onReconnect} />
          ) : server.status === "pending" ? (
            <PendingState />
          ) : (
            <span className="acpmux-session-info-row__end" data-state={server.status}>
              {t(server.status === "failed" ? "sessionInfo.connectors.needsReconnect" : "composer.envConnected")}
            </span>
          )}
        </li>
      ))}
    </ul>
  );
}

/// A server the harness is still connecting: its row's end says Connecting only once that has lasted the
/// shared bound (lasting.ts `CONNECTION_QUIET_MS`), so a server that comes up in a few seconds never shows
/// it. The row mounts this as the server turns pending, so each one waits its own bound. Its way out is the
/// harness's: the server connects, or fails and the row offers Reconnect.
function PendingState() {
  const t = useT();
  const lasting = useConnectionQuiet(true);
  return (
    <span className="acpmux-session-info-row__end" data-state="pending">
      {lasting ? t("rail.connectorPending") : null}
    </span>
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
      ? "sessionInfo.connectors.reconnecting"
      : state === "failed"
        ? "sessionInfo.connectors.retry"
        : "sessionInfo.connectors.reconnectAction",
  );
  return (
    <button
      type="button"
      className="acpmux-session-info-link acpmux-session-info-row__end"
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
