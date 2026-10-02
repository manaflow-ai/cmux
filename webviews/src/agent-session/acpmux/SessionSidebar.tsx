import React, { memo, useMemo, useState } from "react";
import {
  groupMark,
  sessionMark,
  shortAge,
  sidebarSections,
  visibleSessions,
  type AcpmuxSessionEntry,
  type SessionMark,
} from "./sessionList";
import {
  ChatsIcon,
  ClockIcon,
  DisconnectedIcon,
  HomeIcon,
  MoreIcon,
  NeedsInputIcon,
  NewChatIcon,
  PullIcon,
  WorkingIcon,
} from "./sidebarIcons";

const MARK_LABELS: Record<Exclude<SessionMark, undefined>, string> = {
  input: "Needs input",
  running: "Working",
  error: "Disconnected",
  unread: "New activity",
};
const MARK_GLYPHS: Record<Exclude<SessionMark, undefined>, React.ReactNode> = {
  input: <NeedsInputIcon />,
  running: <WorkingIcon />,
  error: <DisconnectedIcon />,
  unread: null,
};

/** What the rail switches the list to. */
export type SidebarView = "sessions" | "history" | "pulls" | "closed";
export type SidebarAccount = { name: string; detail?: string };

const VIEW_TITLES: Record<Exclude<SidebarView, "sessions">, string> = {
  history: "History",
  pulls: "Pull requests",
  closed: "Closed sessions",
};

/** The pane's sidebar: an icon rail, the list it switches, and the account at the bottom. */
export function SessionSidebar({
  sessions,
  selectedId,
  onSelect,
  onNewChat,
  account,
}: {
  sessions: AcpmuxSessionEntry[];
  selectedId?: string;
  onSelect: (sessionId: string) => void;
  onNewChat?: () => void;
  account?: SidebarAccount;
}) {
  const [view, setView] = useState<SidebarView>("sessions");
  const needsInput = useMemo(
    () => sessions.some((session) => sessionMark(session, session.sessionId === selectedId) === "input"),
    [sessions, selectedId],
  );
  return (
    <nav className="acpmux-sidebar" id="acpmux-sidebar" aria-label="Sessions">
      <div className="acpmux-rail">
        <RailButton label="New chat" title="Home: new chat" onClick={onNewChat} icon={<HomeIcon />} />
        <RailButton
          label="Sessions"
          current={view === "sessions"}
          dot={needsInput}
          onClick={() => setView("sessions")}
          icon={<ChatsIcon />}
        />
        <RailButton
          label="History"
          current={view === "history"}
          onClick={() => setView("history")}
          icon={<ClockIcon />}
        />
        <RailButton
          label="Pull requests"
          current={view === "pulls"}
          onClick={() => setView("pulls")}
          icon={<PullIcon />}
        />
        <RailButton
          label="Closed sessions"
          title="More: closed sessions"
          current={view === "closed"}
          onClick={() => setView("closed")}
          icon={<MoreIcon />}
        />
      </div>
      <div className="acpmux-sidebar-body">
        <div className="acpmux-sidebar-scroll">
          {view === "sessions" ? (
            <SessionsView sessions={sessions} selectedId={selectedId} onSelect={onSelect} onNewChat={onNewChat} />
          ) : (
            <FlatView view={view} sessions={sessions} selectedId={selectedId} onSelect={onSelect} />
          )}
        </div>
        {account && (
          <div className="acpmux-account">
            <span className="acpmux-avatar" aria-hidden="true">
              {account.name.slice(0, 1).toUpperCase()}
            </span>
            <span className="acpmux-account-name">{account.name}</span>
            {account.detail && <span className="acpmux-account-detail">{account.detail}</span>}
          </div>
        )}
      </div>
    </nav>
  );
}

function RailButton({
  label,
  title,
  icon,
  current,
  dot,
  onClick,
}: {
  label: string;
  title?: string;
  icon: React.ReactNode;
  current?: boolean;
  dot?: boolean;
  onClick?: () => void;
}) {
  return (
    <button
      type="button"
      className="acpmux-rail-button"
      aria-label={dot ? `${label}, needs input` : label}
      title={title ?? label}
      aria-current={current ? "page" : undefined}
      disabled={!onClick}
      onClick={onClick}
    >
      {icon}
      {dot && <span className="acpmux-rail-dot" aria-hidden="true" />}
    </button>
  );
}

/** Pinned sessions, then every other acpmux session grouped by folder, newest first. */
function SessionsView({
  sessions,
  selectedId,
  onSelect,
  onNewChat,
}: {
  sessions: AcpmuxSessionEntry[];
  selectedId?: string;
  onSelect: (sessionId: string) => void;
  onNewChat?: () => void;
}) {
  const newChat = onNewChat && (
    <button type="button" className="acpmux-sidebar-action" onClick={onNewChat}>
      <NewChatIcon />
      <span>New chat</span>
    </button>
  );
  const { pinned, groups } = useMemo(() => sidebarSections(sessions), [sessions]);
  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  if (sessions.length === 0)
    return (
      <>
        {newChat}
        <div className="acpmux-sidebar-empty">No sessions yet</div>
      </>
    );
  // Section labels only earn their place when both sections show.
  const labelled = pinned.length > 0 && groups.length > 0;
  return (
    <>
      {newChat}
      {pinned.length > 0 && (
        <section className="acpmux-sidebar-pinned" aria-label="Pinned">
          {labelled && (
            <div className="acpmux-sidebar-section" aria-hidden="true">
              Pinned
            </div>
          )}
          <ul>
            {pinned.map((session) => (
              <SessionRow
                key={session.sessionId}
                session={session}
                selected={session.sessionId === selectedId}
                onSelect={onSelect}
              />
            ))}
          </ul>
        </section>
      )}
      {groups.length > 0 && (
        <section className="acpmux-sidebar-projects" aria-label="Projects">
          {labelled && (
            <div className="acpmux-sidebar-section" aria-hidden="true">
              Projects
            </div>
          )}
          {groups.map((group) => {
            const { rows, hidden } = visibleSessions(group, expanded.has(group.key), selectedId);
            const mark = groupMark(group, selectedId);
            return (
              <section className="acpmux-sidebar-group" key={group.key}>
                <div
                  className="acpmux-sidebar-project"
                  title={group.host ? `${group.cwd ?? ""} on ${group.host}` : group.cwd}
                >
                  <FolderIcon />
                  <span>{group.label}</span>
                  {group.host && <small className="acpmux-sidebar-host">{group.host}</small>}
                  {mark && (
                    <span className={`acpmux-session-mark acpmux-session-mark-${mark}`} title={MARK_LABELS[mark]}>
                      {MARK_GLYPHS[mark]}
                      <span className="acpmux-hidden-label">{MARK_LABELS[mark]}</span>
                    </span>
                  )}
                </div>
                <ul>
                  {rows.map((session) => (
                    <SessionRow
                      key={session.sessionId}
                      session={session}
                      selected={session.sessionId === selectedId}
                      onSelect={onSelect}
                    />
                  ))}
                </ul>
                {hidden > 0 && (
                  <button
                    type="button"
                    className="acpmux-sidebar-more"
                    onClick={() => setExpanded((current) => new Set(current).add(group.key))}
                    aria-label={`Show more, ${hidden} hidden`}
                  >
                    Show more
                  </button>
                )}
              </section>
            );
          })}
        </section>
      )}
    </>
  );
}

/** The open-folder glyph from the Codex sidebar, drawn in the muted text colour. */
function FolderIcon() {
  return (
    <svg
      width="16"
      height="16"
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.25"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <path d="M1.4 11.7V4.3c0-.7.5-1.2 1.2-1.2h2.9l1.4 1.5h4.6c.7 0 1.2.5 1.2 1.2v.9" />
      <path d="M1.5 12.3 3.3 7.6c.2-.5.6-.8 1.1-.8h9.5c.6 0 1 .6.8 1.1l-1.6 4.4c-.2.5-.6.7-1.1.7H2.4c-.5 0-.9-.3-.9-.7Z" />
    </svg>
  );
}

/** History, pull requests and closed sessions: one list, newest first. */
function FlatView({
  view,
  sessions,
  selectedId,
  onSelect,
}: {
  view: Exclude<SidebarView, "sessions">;
  sessions: AcpmuxSessionEntry[];
  selectedId?: string;
  onSelect: (sessionId: string) => void;
}) {
  // Pull requests appear once the session summary reports them; until then the view says so.
  const rows = useMemo(
    () =>
      view === "pulls"
        ? []
        : sessions
            .filter((session) => view === "history" || session.status === "closed")
            .sort((left, right) => (right.updatedAt ?? 0) - (left.updatedAt ?? 0)),
    [sessions, view],
  );
  const now = Date.now();
  return (
    <section aria-label={VIEW_TITLES[view]}>
      <h2 className="acpmux-sidebar-title">{VIEW_TITLES[view]}</h2>
      {rows.length === 0 ? (
        <div className="acpmux-sidebar-empty">{view === "pulls" ? "No pull requests yet" : "Nothing here yet"}</div>
      ) : (
        <ul>
          {rows.map((session) => (
            <SessionRow
              key={session.sessionId}
              session={session}
              selected={session.sessionId === selectedId}
              onSelect={onSelect}
              flat
              trailing={shortAge(session.updatedAt, now)}
            />
          ))}
        </ul>
      )}
    </section>
  );
}

const SessionRow = memo(function SessionRow({
  session,
  selected,
  onSelect,
  flat,
  trailing,
}: {
  session: AcpmuxSessionEntry;
  selected: boolean;
  onSelect: (sessionId: string) => void;
  flat?: boolean;
  trailing?: string;
}) {
  const mark = sessionMark(session, selected);
  const title = session.displayTitle || session.sessionId.slice(0, 8);
  return (
    <li>
      <button
        type="button"
        className={`acpmux-session-row${flat ? " is-flat" : ""}${selected ? " is-selected" : ""}${session.status === "closed" ? " is-closed" : ""}`}
        aria-current={selected ? "true" : undefined}
        aria-label={
          mark || trailing ? [title, trailing, mark && MARK_LABELS[mark]].filter(Boolean).join(", ") : undefined
        }
        title={title}
        onClick={() => onSelect(session.sessionId)}
      >
        <span className="acpmux-session-row-title">{title}</span>
        {trailing && (
          <span className="acpmux-session-trailing" aria-hidden="true">
            {trailing}
          </span>
        )}
        {mark && (
          <span
            className={`acpmux-session-mark acpmux-session-mark-${mark}`}
            aria-hidden="true"
            title={MARK_LABELS[mark]}
          >
            {MARK_GLYPHS[mark]}
          </span>
        )}
      </button>
    </li>
  );
});
