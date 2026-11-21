// The chats this chat's agent started (acpmux `spawnedBy`, started/startedSessions.ts), a chat on a
// Cloud VM or another machine included (that machine's daemon lists its children with the chat's
// attachment), as rows under Subagents after the harness's own subagents: the summary card's list
// (summary/SubagentStatusList.tsx), shown with Session Info off. Session Info draws them as
// subagent lines instead (SubagentsSection.tsx, with `sessionStatus` and `sessionStateLabel`). A chat icon, its title and
// its live state in words. Waiting on the person first, then running, failed and idle
// (`orderedSessions`). A row opens that chat.
import { useT } from "../i18n";
import { Spinner } from "../conversation/icons";
import { SenderIcon } from "../subagents/SenderIcon";
import { agentTone } from "../subagents/agentTones";
import { rowIconSize } from "../icons/iconSize";
import type { StartedSession } from "../started/startedSessions";
import { sessionStatus, sessionStateText, orderedSessions } from "./childSessionRowsModel";
import { WindowedRows } from "./WindowedRows";

const ROW_ICON = rowIconSize(12);

export function ChildSessionRows({
  sessions,
  onOpen,
}: {
  sessions: readonly StartedSession[];
  onOpen?: (sessionId: string) => void;
}) {
  const t = useT();
  return (
    <>
      <WindowedRows
        items={orderedSessions(sessions)}
        render={(child) => {
          const status = sessionStatus(child);
          const label = sessionStateText(t, child);
          return (
            <li key={child.sessionId}>
              <button
                type="button"
                className="acpmux-summary-row acpmux-summary-link acpmux-summary-agent acpmux-summary-session"
                data-status={status}
                disabled={!onOpen}
                onClick={() => onOpen?.(child.sessionId)}
              >
                {/* Its harness's mark, else the chat icon in its own stable tone (Leo, 2026-10-29: "all of
                  these icons that are literally all the same icon, that's terrible"). */}
                <span className="acpmux-lineage__icon" data-state={status}>
                  <SenderIcon
                    harness={child.harness}
                    tone={agentTone(child.sessionId)}
                    size={ROW_ICON}
                    fallback="agent.chat"
                  />
                </span>
                <span className="acpmux-summary-text">
                  <span className="acpmux-summary-agent__name">{child.title}</span>
                </span>
                <span className="acpmux-summary-meta acpmux-summary-agent__state">
                  {label.working && <Spinner size={ROW_ICON} loading />}
                  {label.text}
                </span>
              </button>
            </li>
          );
        }}
      />
    </>
  );
}
