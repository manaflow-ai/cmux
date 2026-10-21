// The chats this chat's agent started (acpmux `spawnedBy`, started/startedSessions.ts), as rows of
// the summary card's Subagents section after the harness's own subagents (SubagentStatusList.tsx):
// a chat icon whose dot says its live state, its title and that state in words. Waiting on the
// person first, then running, failed and idle (backgroundWork.ts `orderedSessions`). A row opens
// that chat.
import { useT, type StringKey } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import type { StartedSession, StartedState } from "../started/startedSessions";
import { orderedSessions } from "./backgroundWork";

const ROW_ICON = rowIconSize(12);

/// Each state's word, and the dot it draws (summary.css `.acpmux-lineage__icon`): an idle chat's
/// turn ended, so it reads done.
const SESSION_STATE: Record<StartedState, { word: StringKey; dot: string }> = {
  running: { word: "subagents.state.running", dot: "running" },
  waiting: { word: "subagents.state.waiting", dot: "waiting" },
  failed: { word: "subagents.state.failed", dot: "failed" },
  idle: { word: "subagents.state.completed", dot: "done" },
};

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
      {orderedSessions(sessions).map((child) => {
        const state = SESSION_STATE[child.state];
        return (
          <li key={child.sessionId}>
            <button
              type="button"
              className="acpmux-summary-row acpmux-summary-link acpmux-summary-agent acpmux-summary-session"
              data-status={state.dot}
              disabled={!onOpen}
              onClick={() => onOpen?.(child.sessionId)}
            >
              <span className="acpmux-lineage__icon" data-state={state.dot}>
                <Icon name="agent.chat" size={ROW_ICON} row />
              </span>
              <span className="acpmux-summary-text">
                <span className="acpmux-summary-agent__name">{child.title}</span>
              </span>
              <span className="acpmux-summary-meta acpmux-summary-agent__state">{t(state.word)}</span>
            </button>
          </li>
        );
      })}
    </>
  );
}
