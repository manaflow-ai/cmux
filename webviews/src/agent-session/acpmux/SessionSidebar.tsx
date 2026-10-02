import React, { memo, useMemo, useState } from "react";
import {
  sessionMark,
  sidebarSections,
  visibleSessions,
  type AcpmuxSessionEntry,
  type SessionMark,
} from "./sessionList";
import { DisconnectedIcon, NeedsInputIcon, WorkingIcon } from "./sidebarIcons";

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

/** The pane's session list: pinned sessions, then every other acpmux session grouped by folder, newest first. */
export function SessionSidebar({
  sessions,
  selectedId,
  onSelect,
}: {
  sessions: AcpmuxSessionEntry[];
  selectedId?: string;
  onSelect: (sessionId: string) => void;
}) {
  const { pinned, groups } = useMemo(() => sidebarSections(sessions), [sessions]);
  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  if (sessions.length === 0)
    return (
      <nav className="acpmux-sidebar" id="acpmux-sidebar" aria-label="Sessions">
        <div className="acpmux-sidebar-empty">No sessions yet</div>
      </nav>
    );
  // Section labels only earn their place when both sections show.
  const labelled = pinned.length > 0 && groups.length > 0;
  return (
    <nav className="acpmux-sidebar" id="acpmux-sidebar" aria-label="Sessions">
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
            return (
              <section className="acpmux-sidebar-group" key={group.key}>
                <div
                  className="acpmux-sidebar-project"
                  title={group.host ? `${group.cwd ?? ""} on ${group.host}` : group.cwd}
                >
                  <FolderIcon />
                  <span>{group.label}</span>
                  {group.host && <small className="acpmux-sidebar-host">{group.host}</small>}
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
    </nav>
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

const SessionRow = memo(function SessionRow({
  session,
  selected,
  onSelect,
}: {
  session: AcpmuxSessionEntry;
  selected: boolean;
  onSelect: (sessionId: string) => void;
}) {
  const mark = sessionMark(session, selected);
  const title = session.displayTitle || session.sessionId.slice(0, 8);
  return (
    <li>
      <button
        type="button"
        className={`acpmux-session-row${selected ? " is-selected" : ""}${session.status === "closed" ? " is-closed" : ""}`}
        aria-current={selected ? "true" : undefined}
        aria-label={mark ? `${title}, ${MARK_LABELS[mark]}` : undefined}
        title={title}
        onClick={() => onSelect(session.sessionId)}
      >
        <span className="acpmux-session-row-title">{title}</span>
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
