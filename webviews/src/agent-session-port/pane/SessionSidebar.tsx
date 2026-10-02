// The in-pane session list, drawn as the reference's sidebar (home.png, overview.png):
// New chat, Projects (one folder per cwd with its newest chats and Show more), Recents.
// Sessions come from acpmux; which projects are expanded is view state.
import { useState } from "react";
import { Sidebar, type SidebarProject, type SidebarThread } from "../shell/Sidebar";
import { groupByProject, type AcpmuxSessionEntry } from "../data/acpmux";

const PROJECT_ROWS = 5;
const RECENT_ROWS = 20;

export type SessionSidebarProps = {
  sessions: AcpmuxSessionEntry[];
  selectedId?: string;
  onSelect: (sessionId: string) => void;
  onNewChat: () => void;
  onSearch?: () => void;
};

const title = (session: AcpmuxSessionEntry) => session.displayTitle ?? session.title ?? session.sessionId.slice(0, 8);

export function SessionSidebar({ sessions, selectedId, onSelect, onNewChat, onSearch }: SessionSidebarProps) {
  const [expanded, setExpanded] = useState<ReadonlySet<string>>(new Set());
  const [hover, setHover] = useState<string>();
  const row = (session: AcpmuxSessionEntry): SidebarThread => ({
    id: session.sessionId,
    title: title(session),
    selected: session.sessionId === selectedId,
    hover: hover === session.sessionId,
  });
  const projects: SidebarProject[] = groupByProject(sessions.filter((session) => session.cwd)).map((group) => {
    const open = expanded.has(group.key);
    const shown = open ? group.sessions : group.sessions.slice(0, PROJECT_ROWS);
    return {
      id: group.key,
      name: group.label,
      threads: shown.map(row),
      showMore: !open && group.sessions.length > PROJECT_ROWS,
    };
  });
  // Recents repeat the newest chats of every project; the selection highlights in Projects.
  const recents = [...sessions]
    .sort((a, b) => (b.updatedAt ?? 0) - (a.updatedAt ?? 0))
    .slice(0, RECENT_ROWS)
    .map((session) => ({ ...row(session), id: `recent:${session.sessionId}`, selected: false }));
  return (
    <Sidebar
      title="Agents"
      projects={projects}
      recents={recents}
      onNewChat={onNewChat}
      onSearch={onSearch}
      onThreadClick={(id) => onSelect(id.replace(/^recent:/, ""))}
      onShowMore={(id) => setExpanded((current) => new Set(current).add(id))}
      onHover={(target) => setHover(target?.kind === "thread" ? target.id : undefined)}
    />
  );
}
