// Session Info's Servers: the dev servers the chat runs in the background (a background command
// whose command serves something, processes.ts `serverOf`), each with the ports its command names
// and a Stop button. A port opens `http://localhost:<port>` beside the chat. Only what the command
// says is shown: a port it does not name is never guessed.
import { formatDuration } from "../conversation/turns";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import { useNow } from "../subagents/SubagentGroup";
import type { SessionInfoServer } from "./processes";
import { StopButton } from "./TasksSection";

const ROW_ICON = rowIconSize(12);

export function ServersSection({
  servers,
  onStop,
  onOpenUrl,
}: {
  servers: readonly SessionInfoServer[];
  onStop?: (id: string) => Promise<unknown>;
  /// Opens a local address beside the chat; a port is plain text without it.
  onOpenUrl?: (url: string) => void;
}) {
  const t = useT();
  const now = useNow(servers.length > 0);
  return (
    <ul className="acpmux-session-info-list acpmux-session-info-scroll" data-section="servers">
      {[...servers]
        .sort((a, b) => b.startedAt - a.startedAt)
        .map((server) => (
          <li key={server.id} className="acpmux-session-info-server">
            <span className="acpmux-session-info-server__dot" aria-hidden="true" />
            <span className="acpmux-session-info-server__text">
              <span className="acpmux-session-info-task__command">{server.command}</span>
              <span className="acpmux-session-info-server__line">
                {server.ports.map((port) => {
                  const url = `http://localhost:${port}`;
                  return onOpenUrl ? (
                    <button
                      key={port}
                      type="button"
                      className="acpmux-session-info-port"
                      aria-label={t("sessionInfo.servers.open", { url })}
                      onClick={() => onOpenUrl(url)}
                    >
                      <Icon name="link.web" size={ROW_ICON} row />:{port}
                    </button>
                  ) : (
                    <span key={port} className="acpmux-session-info-port">
                      :{port}
                    </span>
                  );
                })}
                <span className="acpmux-session-info-task__time">
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
