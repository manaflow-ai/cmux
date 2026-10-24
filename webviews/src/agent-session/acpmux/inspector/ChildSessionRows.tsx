// The chats this chat's agent started (acpmux `spawnedBy`, started/startedSessions.ts), a chat on a
// Cloud VM or another machine included (that machine's daemon lists its children with the chat's
// attachment), as rows under Subagents after the harness's own subagents: the summary card's list
// (summary/SubagentStatusList.tsx), shown with the Inspector off. The Inspector draws them as
// subagent lines instead (SubagentsSection.tsx, with `sessionStatus` and `sessionStateLabel`). A chat icon, its title and
// its live state in words. Waiting on the person first, then running, failed and idle
// (`orderedSessions`). A row opens that chat.
import { useT, type StringKey } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import type { StartedSession, StartedState } from "../started/startedSessions";
import type { SubagentStatus } from "../summary/SubagentStatusList";

const ROW_ICON = rowIconSize(12);

/// Each state's word, and the status it counts as beside the subagents: an idle chat's turn ended,
/// so it reads done.
const SESSION_STATE: Record<StartedState, { word: StringKey; status: SubagentStatus }> = {
  running: { word: "subagents.state.running", status: "running" },
  waiting: { word: "subagents.state.waiting", status: "waiting" },
  failed: { word: "subagents.state.failed", status: "failed" },
  idle: { word: "subagents.state.completed", status: "done" },
};

/// A started chat's status as a subagent's reads, for the counts and the Active and Done lists.
export const sessionStatus = (child: StartedSession): SubagentStatus => SESSION_STATE[child.state].status;

/// A started chat's state in words ("Running", "Done"), as its row says it.
export const sessionStateLabel = (child: StartedSession): StringKey => SESSION_STATE[child.state].word;

/// The started chats in list order: waiting on the person first, then running, failed and idle,
/// each newest first.
export function orderedSessions(sessions: readonly StartedSession[]): StartedSession[] {
  const rank = { waiting: 0, running: 1, failed: 2, idle: 3 } as const;
  return [...sessions].sort(
    (a, b) => rank[a.state] - rank[b.state] || (b.createdAt ?? -Infinity) - (a.createdAt ?? -Infinity),
  );
}

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
              data-status={state.status}
              disabled={!onOpen}
              onClick={() => onOpen?.(child.sessionId)}
            >
              <span className="acpmux-lineage__icon" data-state={state.status}>
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
