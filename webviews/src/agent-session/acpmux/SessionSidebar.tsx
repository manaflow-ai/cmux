import React, { memo, useMemo, useState } from "react";
import {
  sessionMark,
  sessionPlace,
  sidebarSections,
  visibleSessions,
  type AcpmuxSessionEntry,
  type SessionMark,
} from "./sessionList";
import {
  BranchIcon,
  CloudIcon,
  DisconnectedIcon,
  NeedsInputIcon,
  SearchIcon,
  WorkingIcon,
  WorktreeIcon,
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
const PLACE_GLYPHS = { cloud: <CloudIcon />, worktree: <WorktreeIcon />, branch: <BranchIcon /> };
const PLACE_LABELS = { cloud: "Runs on", worktree: "Worktree", branch: "Branch" };

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
  const [query, setQuery] = useState("");
  const searching = query.trim() !== "";
  const { pinned, groups } = useMemo(() => sidebarSections(sessions, query), [sessions, query]);
  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  if (sessions.length === 0)
    return (
      <nav className="acpmux-sidebar" id="acpmux-sidebar" aria-label="Sessions">
        <div className="acpmux-sidebar-empty">No sessions yet</div>
      </nav>
    );
  // Section labels only earn their place when both sections show.
  const labelled = pinned.length > 0 && groups.length > 0;
  // Escape clears a query first; with the field empty it reaches the overlay, which closes.
  const onSearchKey = (event: React.KeyboardEvent<HTMLInputElement>) => {
    if (event.key !== "Escape") return;
    // During IME composition Escape cancels the composition, and closes nothing.
    // WebKit can end the composition before this keydown, which then reports only keyCode 229.
    const composing = event.nativeEvent.isComposing || event.nativeEvent.keyCode === 229;
    if (!composing && !query) return;
    event.stopPropagation();
    if (!composing) setQuery("");
  };
  return (
    <nav className="acpmux-sidebar" id="acpmux-sidebar" aria-label="Sessions">
      <search className="acpmux-sidebar-search">
        <label>
          <SearchIcon />
          <input
            type="search"
            aria-label="Search sessions"
            placeholder="Search"
            spellCheck={false}
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            onKeyDown={onSearchKey}
          />
        </label>
      </search>
      {/* Always present, so a screen reader announces the text when it appears. */}
      <output className="acpmux-sidebar-empty">
        {pinned.length === 0 && groups.length === 0 ? "No matching sessions" : ""}
      </output>
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
            // A search shows every match, so it never hides rows behind "Show more".
            const { rows, hidden } = visibleSessions(group, searching || expanded.has(group.key), selectedId);
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
                      groupHost={group.host}
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
  groupHost,
  onSelect,
}: {
  session: AcpmuxSessionEntry;
  selected: boolean;
  groupHost?: string;
  onSelect: (sessionId: string) => void;
}) {
  const mark = sessionMark(session, selected);
  const title = session.displayTitle || session.sessionId.slice(0, 8);
  const place = sessionPlace(session, groupHost);
  const placeLabel =
    place &&
    `${PLACE_LABELS[place.kind]} ${place.label}${place.branch ? `, ${PLACE_LABELS.branch} ${place.branch}` : ""}`;
  return (
    <li>
      <button
        type="button"
        className={`acpmux-session-row${selected ? " is-selected" : ""}${session.status === "closed" ? " is-closed" : ""}`}
        aria-current={selected ? "true" : undefined}
        aria-label={
          mark || place ? [title, placeLabel, mark && MARK_LABELS[mark]].filter(Boolean).join(", ") : undefined
        }
        title={placeLabel ? `${title}\n${placeLabel}` : title}
        onClick={() => onSelect(session.sessionId)}
      >
        <span className="acpmux-session-row-title">{title}</span>
        {place && (
          <span className={`acpmux-session-place acpmux-session-place-${place.kind}`} aria-hidden="true">
            {PLACE_GLYPHS[place.kind]}
          </span>
        )}
        {mark ? (
          <span
            className={`acpmux-session-mark acpmux-session-mark-${mark}`}
            aria-hidden="true"
            title={MARK_LABELS[mark]}
          >
            {MARK_GLYPHS[mark]}
          </span>
        ) : (
          // Keeps place glyphs in one column.
          place && <span className="acpmux-session-mark" aria-hidden="true" />
        )}
      </button>
    </li>
  );
});
