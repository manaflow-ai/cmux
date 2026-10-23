// The Inspector's Servers: the dev servers the chat runs in the background (a background command
// whose command serves something, processes.ts `serverOf`), each with the ports its command names
// and a Stop button. A port opens `http://localhost:<port>` beside the chat. Only what the command
// says is shown: a port it does not name is never guessed.
import { useState } from "react";
import { formatDuration } from "../conversation/turns";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import { useNow } from "../subagents/SubagentGroup";
import type { InspectorServer } from "./processes";
import { StopButton } from "./TasksSection";
import type { InspectorListMode } from "./OutputsSection";

const ROW_ICON = rowIconSize(12);
const SERVERS_SHOWN = 6;

export function ServersSection({
  servers,
  onStop,
  onOpenUrl,
  listMode = "view-all",
}: {
  servers: readonly InspectorServer[];
  onStop?: (id: string) => Promise<unknown>;
  /// Opens a local address beside the chat; a port is plain text without it.
  onOpenUrl?: (url: string) => void;
  listMode?: InspectorListMode;
}) {
  const t = useT();
  const [all, setAll] = useState(false);
  const now = useNow(servers.length > 0);
  const ordered = [...servers].sort((a, b) => b.startedAt - a.startedAt);
  const shown = listMode === "view-all" && !all ? ordered.slice(0, SERVERS_SHOWN) : ordered;
  return (
    <ul
      className="acpmux-chat-inspector-list acpmux-chat-inspector-scroll"
      data-section="servers"
      data-list-mode={listMode}
    >
      {shown.map((server) => (
        <li key={server.id} className="acpmux-chat-inspector-server">
          <span className="acpmux-chat-inspector-server__dot" aria-hidden="true" />
          <span className="acpmux-chat-inspector-server__text">
            <span className="acpmux-chat-inspector-task__command">{server.command}</span>
            <span className="acpmux-chat-inspector-server__line">
              {server.ports.map((port) => {
                const url = `http://localhost:${port}`;
                return onOpenUrl ? (
                  <button
                    key={port}
                    type="button"
                    className="acpmux-chat-inspector-port"
                    aria-label={t("chatInspector.servers.open", { url })}
                    onClick={() => onOpenUrl(url)}
                  >
                    <Icon name="link.web" size={ROW_ICON} row />:{port}
                  </button>
                ) : (
                  <span key={port} className="acpmux-chat-inspector-port">
                    :{port}
                  </span>
                );
              })}
              <span className="acpmux-chat-inspector-task__time">
                {formatDuration(Math.max(0, now - server.startedAt))}
              </span>
            </span>
          </span>
          {onStop && <StopButton id={server.id} name={server.command} stop={onStop} />}
        </li>
      ))}
      {listMode === "view-all" && ordered.length > SERVERS_SHOWN && (
        <li>
          <button type="button" className="acpmux-chat-inspector-fold" onClick={() => setAll(!all)}>
            {all ? t("summary.showFewer") : t("summary.viewAll", { n: ordered.length })}
          </button>
        </li>
      )}
    </ul>
  );
}
