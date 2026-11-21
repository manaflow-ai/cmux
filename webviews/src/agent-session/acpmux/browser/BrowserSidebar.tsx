import { memo, useMemo, useState } from "react";
import { AgentMark } from "../../shared/AgentMark";
import { useT } from "../i18n";
import { activityTime, listed, sessionTitle, type AcpmuxSessionEntry } from "../sessionList";
import { linkedSessions, matchingWorkspaces, type BrowserWorkspaceChat, type BrowserWorkspaces } from "./workspaces";

export const BrowserSidebar = memo(function BrowserSidebar({
  sessions,
  workspaces,
  selected,
  onSelect,
  onRefresh,
}: {
  sessions: AcpmuxSessionEntry[];
  workspaces?: BrowserWorkspaces;
  selected?: string;
  onSelect(id: string): void;
  onRefresh?(): void;
}) {
  const t = useT();
  const [query, setQuery] = useState("");
  const [limit, setLimit] = useState(60);
  const needle = query.trim().toLocaleLowerCase();
  const sessionById = useMemo(() => new Map(sessions.map((row) => [row.sessionId, row])), [sessions]);
  const linked = useMemo(() => linkedSessions(workspaces), [workspaces]);
  const matches = useMemo(
    () =>
      sessions
        .filter(listed)
        .filter((row) => !linked.has(row.sessionId))
        .filter(
          (row) =>
            !needle ||
            [sessionTitle(row, t), row.cwd, row.peer].some((part) => part?.toLocaleLowerCase().includes(needle)),
        )
        .sort((a, b) => Number(!!b.pinned) - Number(!!a.pinned) || (activityTime(b) ?? 0) - (activityTime(a) ?? 0)),
    [sessions, linked, needle, t],
  );
  const chatSession = (chat: BrowserWorkspaceChat) =>
    chat.local && chat.sessionId ? sessionById.get(chat.sessionId) : undefined;
  const chatTitle = (chat: BrowserWorkspaceChat) => {
    const session = chatSession(chat);
    return session ? sessionTitle(session, t) : chat.title;
  };
  const visibleWorkspaces = matchingWorkspaces(workspaces, needle, chatTitle);
  return (
    <nav className="acpmux-browser-sidebar" aria-label={t("ledger.group.workspace")}>
      <div className="acpmux-browser-sidebar-heading">
        <h2>{t("ledger.group.workspace")}</h2>
        {onRefresh && (
          <button type="button" onClick={onRefresh}>
            {t("permission.refresh")}
          </button>
        )}
      </div>
      <input
        type="search"
        value={query}
        aria-label={t("sidebar.search")}
        placeholder={t("sidebar.searchPlaceholder")}
        onChange={(event) => {
          setQuery(event.currentTarget.value);
          setLimit(60);
        }}
      />
      {workspaces && !workspaces.available && <p role="status">{t("picker.unavailable")}</p>}
      {visibleWorkspaces.map((workspace) => (
        <details key={`${workspaces?.registryId}:${workspace.id}`} data-workspace={workspace.id} open>
          <summary title={workspace.title || workspace.name}>{workspace.title || workspace.name}</summary>
          <div className="acpmux-browser-workspace-chats">
            {!workspace.chats.length && <p>{t("sidebar.noSessions")}</p>}
            {workspace.chats.map((chat) => {
              const session = chatSession(chat);
              const title = chatTitle(chat) || t("sidebar.newChat");
              return (
                <button
                  key={chat.tabId}
                  type="button"
                  data-chat={chat.sessionId}
                  data-tab={chat.tabId}
                  disabled={!chat.local || !chat.sessionId}
                  aria-current={chat.local && chat.sessionId === selected ? "page" : undefined}
                  title={chat.local ? title : `${title} · ${chat.host}`}
                  onClick={() => {
                    if (chat.local && chat.sessionId) onSelect(chat.sessionId);
                  }}
                >
                  <AgentMark agent={session?.harness ?? chat.harness} size={16} tint />
                  <span>{title}</span>
                </button>
              );
            })}
          </div>
        </details>
      ))}
      <h2>{t("sidebar.sessions")}</h2>
      {!matches.length && !visibleWorkspaces.length && <p>{t(query ? "sidebar.noMatches" : "sidebar.noSessions")}</p>}
      {matches.slice(0, limit).map((row) => (
        <button
          key={row.sessionId}
          type="button"
          data-chat={row.sessionId}
          aria-current={row.sessionId === selected ? "page" : undefined}
          title={[sessionTitle(row, t), row.peer, row.cwd].filter(Boolean).join(" · ")}
          onClick={() => onSelect(row.sessionId)}
        >
          <AgentMark agent={row.harness} size={16} tint />
          <span>{sessionTitle(row, t)}</span>
        </button>
      ))}
      {matches.length > limit && (
        <button type="button" onClick={() => setLimit(limit + 60)}>
          {t("backgroundTasks.showMore")}
        </button>
      )}
    </nav>
  );
});
