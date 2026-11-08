// Background tasks' dev servers: the background commands whose command serves something (processes.ts
// `serverOf`), drawn as Background tasks' own rows at the head of that section, never a section of
// their own. A row is the globe, the address the command names (`localhost:5173`), then the command in
// grey; a click opens that address beside the chat. Its time ends the row, and on the row's hover or
// focus Stop takes the time's place (sessionInfo.css), as every running task's does (Lucas,
// 2026-11-05, Session Info lab: "if its a server ... recognise that and give it a stop icon"). Only
// what the command says is shown: a port it does not name is never guessed, and a server with none is
// its command alone.
import { formatDuration } from "../conversation/turns";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import { useNow } from "../subagents/subagentGroupModel";
import { previewAddress } from "../conversation/previewChipModel";
import { serverUrl, type SessionInfoServer } from "./processes";
import { StopButton } from "./TasksSection";

const ROW_ICON = rowIconSize(12);

export function ServersSection({
  servers,
  onStop,
  onOpenUrl,
}: {
  servers: readonly SessionInfoServer[];
  onStop?: (id: string) => Promise<unknown>;
  /// Opens a local address beside the chat; the row is plain text without it.
  onOpenUrl?: (url: string) => void;
}) {
  const t = useT();
  const now = useNow(servers.length > 0);
  return (
    <ul className="acpmux-session-info-list" data-section="servers">
      {[...servers]
        .sort((a, b) => b.startedAt - a.startedAt)
        .map((server) => {
          const port = server.ports[0];
          const url = port === undefined ? undefined : serverUrl(server, port);
          const address = url && previewAddress(url);
          const open = url && onOpenUrl ? () => onOpenUrl(url) : undefined;
          return (
            <li
              key={server.id}
              className="acpmux-session-info-task acpmux-session-info-task--command"
              data-kind="server"
              data-state="running"
              // tooltip-allow: the row cuts a long command; its whole text appears nowhere else.
              title={server.command}
            >
              <button
                type="button"
                className="acpmux-session-info-task__open"
                disabled={!open}
                aria-label={url ? t("sessionInfo.servers.open", { url }) : undefined}
                onClick={open}
              >
                <Icon name="link.web" size={ROW_ICON} row fit className="acpmux-row-glyph" />
                {address && <span className="acpmux-session-info-task__address">{address}</span>}
                <span className="acpmux-session-info-task__command" data-detail={address ? "" : undefined}>
                  {server.command}
                </span>
                <span className="acpmux-session-info-task__time">
                  {formatDuration(Math.max(0, now - server.startedAt))}
                </span>
              </button>
              {onStop && <StopButton id={server.id} name={server.command} stop={onStop} solid />}
            </li>
          );
        })}
    </ul>
  );
}
