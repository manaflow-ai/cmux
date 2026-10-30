// The Inspector's Servers: the dev servers the chat runs in the background (a background command
// whose command serves something, processes.ts `serverOf`), each with the ports its command names
// and a Stop button. A port opens `http://localhost:<port>` beside the chat. Only what the command
// says is shown: a port it does not name is never guessed.
import { formatDuration } from "../conversation/turns";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import { useNow } from "../subagents/SubagentGroup";
import type { InspectorServer } from "./processes";
import { StopButton } from "./TasksSection";

const ROW_ICON = rowIconSize(12);

export function ServersSection({
  servers,
  onStop,
  onOpenUrl,
}: {
  servers: readonly InspectorServer[];
  onStop?: (id: string) => Promise<unknown>;
  /// Opens a local address beside the chat; a port is plain text without it.
  onOpenUrl?: (url: string) => void;
}) {
  const t = useT();
  const now = useNow(servers.length > 0);
  return (
    <ul className="acpmux-chat-inspector-list acpmux-chat-inspector-scroll" data-section="servers">
      {[...servers]
        .sort((a, b) => b.startedAt - a.startedAt)
        .map((server) => (
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
    </ul>
  );
}
