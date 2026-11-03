// Session Info's Connectors, drawn by the App (ConnectorsSection.tsx): one row per MCP server the
// chat's harness loaded with its state; a failed one has Reconnect where acpmux reconnects one.
import type { AcpmuxSnapshot } from "../../model";
import type { Translate } from "../../i18n";
import type { NativeInfoActions, NativeInfoRow, NativeInfoSection, NativeInfoTone } from "./model";
import { imessageError, type IMessageView } from "../imessage";

type McpServer = NonNullable<NonNullable<AcpmuxSnapshot["summary"]>["mcpServers"]>[number];

export const CONNECTORS_SYMBOL = "puzzlepiece.extension";

const TONES: Record<McpServer["status"], NativeInfoTone> = {
  failed: "failed",
  connected: "done",
  pending: "waiting",
};

export type ConnectorsInput = {
  /// `summary.mcpServers`.
  servers: readonly McpServer[];
  /// `_acpmux/mcp/reconnect` of the server by its name.
  onReconnect?: (server: string) => Promise<unknown>;
  /// The section is unfolded (`sections.connectors`).
  open: boolean;
  /// A Reconnect under way or failed, by server (ReconnectButton's own state, held by the caller).
  reconnecting?: Readonly<Record<string, "reconnecting" | "failed">>;
  imessage?: IMessageView;
};

export function connectorsSection(
  input: ConnectorsInput,
  actions: NativeInfoActions,
  t: Translate,
): NativeInfoSection | undefined {
  const { servers, onReconnect } = input;
  if (servers.length === 0 && !input.imessage) return undefined;
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
                ? "sessionInfo.connectors.reconnecting"
                : state === "failed"
                  ? "sessionInfo.connectors.retry"
                  : "sessionInfo.connectors.reconnectAction",
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
          ? "sessionInfo.connectors.needsReconnect"
          : server.status === "pending"
            ? "rail.connectorPending"
            : "composer.envConnected",
      ),
    };
  });
  const imessage = input.imessage;
  if (imessage) {
    const { data, busy, expanded, perform, toggle } = imessage;
    const button = (action: Parameters<typeof perform>[0], label: string) => ({
      label,
      disabled: busy,
      action: actions.add(`imessage:${action}`, () => perform(action)),
    });
    const connected = data.status === "connected";
    rows.unshift({
      id: "imessage",
      symbol: "message",
      title: "iMessage", // l10n-allow: Apple's invariant product name.
      trailing: connected
        ? t("composer.envConnected")
        : data.status !== "not_connected"
          ? t("imessage.setup")
          : undefined,
      action: connected ? actions.add("imessage:toggle", toggle) : undefined,
      buttons: data.status === "not_connected" ? [button("connect", t("imessage.connect"))] : undefined,
    });
    const details: NativeInfoRow[] = [];
    if (data.error)
      details.push({
        id: "imessage:error",
        title: imessageError(data.error, t),
        tone: "failed",
        indent: 1,
      });
    if (data.status === "needs_full_disk_access")
      details.push({
        id: "imessage:disk",
        title: t("imessage.diskHelp"),
        indent: 1,
        buttons: [
          button("full_disk_access", t("imessage.grantDisk")),
          button("disconnect", t("permission.feedbackCancel")),
        ],
      });
    if (data.status === "needs_automation")
      details.push({
        id: "imessage:automation",
        title: t("imessage.automationHelp"),
        indent: 1,
        buttons: [
          button("automation", t("imessage.allowMessages")),
          button("skip_automation", t("question.skip")),
          button("disconnect", t("permission.feedbackCancel")),
        ],
      });
    if (connected && expanded) {
      details.push({
        id: "imessage:consent",
        title: t("imessage.sendClick"),
        indent: 1,
        tone: "muted",
      });
      details.push({ id: "imessage:threads", title: t("imessage.contactsGroups"), indent: 1 });
      details.push(
        ...data.threads.map((thread): NativeInfoRow => ({
          id: `imessage:thread:${thread.chat_id}`,
          title: thread.title || thread.participants.join(", "),
          symbol: thread.is_group ? "person.2" : "person",
          indent: 1,
        })),
      );
      if (!busy && !data.error && data.threads.length === 0)
        details.push({
          id: "imessage:empty",
          title: t("imessage.noThreads"),
          indent: 1,
          tone: "muted",
        });
      details.push({
        id: "imessage:disconnect",
        title: "",
        indent: 1,
        buttons: [
          ...(!data.sends_enabled ? [button("automation", t("imessage.allowMessages"))] : []),
          ...(data.error ? [button("threads", t("sessionInfo.connectors.retry"))] : []),
          button("disconnect", t("imessage.disconnect")),
        ],
      });
    }
    rows.splice(1, 0, ...details);
  }
  return {
    id: "connectors",
    group: "about",
    title: t("rail.connectors"),
    symbol: CONNECTORS_SYMBOL,
    // As Claude Code desktop's: the servers to reconnect when any failed, else the connected ones.
    meta:
      reconnect > 0
        ? t("sessionInfo.connectors.reconnect", { count: reconnect })
        : servers.length === 0 && imessage && imessage.data.status !== "connected"
          ? t("imessage.connect")
          : t("rail.connected", {
              count:
                servers.filter((server) => server.status === "connected").length +
                (servers.length === 0 && imessage?.data.status === "connected" ? 1 : 0),
            }),
    open: input.open,
    foldable: true,
    reorderable: true,
    rows,
  };
}
