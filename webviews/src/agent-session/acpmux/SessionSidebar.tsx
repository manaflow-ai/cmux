import React, { createContext, memo, useContext, useEffect, useMemo, useState } from "react";
import {
  groupMark,
  sessionMark,
  sessionPlace,
  shortAge,
  sidebarSections,
  visibleSessions,
  type AcpmuxSessionEntry,
  type SessionMark,
} from "./sessionList";
import { type StringKey, useT } from "./i18n";
import { Icon } from "./icons/Icon";
import { rowIconSize } from "./icons/iconSize";

const MARK_LABELS = {
  input: "sidebar.markInput",
  running: "sidebar.markRunning",
  error: "sidebar.markError",
  unread: "sidebar.markUnread",
} as const satisfies Record<Exclude<SessionMark, undefined>, StringKey>;
/** Sidebar rows set 13px text, so their icons draw at the registry's row size for it. */
const ROW_ICON = rowIconSize(13);
/** The rail's icon-only buttons keep the 18px glyphs' footprint: a 15px row crop inks about 14px. */
const RAIL_ICON = 15;
const MARK_GLYPHS: Record<Exclude<SessionMark, undefined>, React.ReactNode> = {
  input: <Icon name="status.needsinput" size={ROW_ICON} row />,
  running: <Icon name="status.running" size={ROW_ICON} row />,
  error: <Icon name="status.disconnected" size={ROW_ICON} row />,
  unread: null,
};
/** Where a session runs is secondary to its title, so its glyph takes the caption size (11px text). */
const PLACE_ICON = rowIconSize(11);
const PLACE_GLYPHS = {
  cloud: <Icon name="cloud" size={PLACE_ICON} row />,
  worktree: <Icon name="git.worktree" size={PLACE_ICON} row />,
  branch: <Icon name="git.branch" size={PLACE_ICON} row />,
};
const PLACE_LABELS = {
  cloud: "sidebar.runsOn",
  worktree: "sidebar.worktree",
  branch: "sidebar.branch",
} as const satisfies Record<string, StringKey>;

/** What the rail switches the list to. */
export type SidebarView = "sessions" | "history" | "pulls" | "closed";
export type SidebarAccount = { name: string; detail?: string };

const VIEW_TITLES = {
  history: "sidebar.history",
  pulls: "sidebar.pulls",
  closed: "sidebar.closed",
} as const satisfies Record<Exclude<SidebarView, "sessions">, StringKey>;

/** Sessions already open in a tab, when the list is a history layer beside them. */
const OpenSessions = createContext<ReadonlySet<string> | undefined>(undefined);

/** The pane's sidebar: an icon rail, the list it switches, and the account at the bottom. */
export function SessionSidebar({
  sessions,
  selectedId,
  openIds,
  onSelect,
  onNewChat,
  account,
  preview = false,
}: {
  sessions: AcpmuxSessionEntry[];
  selectedId?: string;
  /** Sessions already open in a tab; their rows say so, and opening one jumps to it. */
  openIds?: ReadonlySet<string>;
  onSelect: (sessionId: string) => void;
  onNewChat?: () => void;
  account?: SidebarAccount;
  /** Preview features are on (`labs.previewFeatures`): the rail offers the Pull requests view. */
  preview?: boolean;
}) {
  const [picked, setView] = useState<SidebarView>("sessions");
  // Pull requests turned off while shown falls back to the session list, and stays there.
  const view = picked === "pulls" && !preview ? "sessions" : picked;
  useEffect(() => {
    if (!preview) setView((current) => (current === "pulls" ? "sessions" : current));
  }, [preview]);
  // Kept here so expanded projects and a search survive a trip to another rail view.
  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  const t = useT();
  const [query, setQuery] = useState("");
  const needsInput = useMemo(
    () => sessions.some((session) => sessionMark(session, session.sessionId === selectedId) === "input"),
    [sessions, selectedId],
  );
  return (
    <OpenSessions.Provider value={openIds}>
      <nav className="acpmux-sidebar" id="acpmux-sidebar" aria-label={t("sidebar.label")}>
        <div className="acpmux-rail">
          <RailButton label={t("sidebar.newChat")} title={t("sidebar.newChatTitle")} onClick={onNewChat} icon="home" />
          <RailButton
            label={t("sidebar.sessions")}
            current={view === "sessions"}
            dot={needsInput}
            onClick={() => setView("sessions")}
            icon="agent.chat.list"
          />
          <RailButton
            label={t("sidebar.history")}
            current={view === "history"}
            onClick={() => setView("history")}
            icon="history"
          />
          {preview && (
            <RailButton
              label={t("sidebar.pulls")}
              current={view === "pulls"}
              onClick={() => setView("pulls")}
              icon="git.pullrequest"
            />
          )}
          <RailButton
            label={t("sidebar.closed")}
            title={t("sidebar.closedTitle")}
            current={view === "closed"}
            onClick={() => setView("closed")}
            icon="action.more"
          />
        </div>
        <div className="acpmux-sidebar-body">
          <div className="acpmux-sidebar-scroll">
            {view === "sessions" ? (
              <SessionsView
                sessions={sessions}
                selectedId={selectedId}
                onSelect={onSelect}
                onNewChat={onNewChat}
                query={query}
                onQuery={setQuery}
                expanded={expanded}
                onExpand={(key) => setExpanded((current) => new Set(current).add(key))}
              />
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
    </OpenSessions.Provider>
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
  /** The registry name of the button's glyph. */
  icon: string;
  current?: boolean;
  dot?: boolean;
  onClick?: () => void;
}) {
  const t = useT();
  return (
    <button
      type="button"
      className="acpmux-rail-button"
      aria-label={dot ? t("sidebar.needsInput", { label }) : label}
      title={title ?? label}
      aria-current={current ? "page" : undefined}
      disabled={!onClick}
      onClick={onClick}
    >
      <Icon name={icon} size={RAIL_ICON} row selected={current} />
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
  query,
  onQuery,
  expanded,
  onExpand,
}: {
  sessions: AcpmuxSessionEntry[];
  selectedId?: string;
  onSelect: (sessionId: string) => void;
  onNewChat?: () => void;
  query: string;
  onQuery: (query: string) => void;
  expanded: Set<string>;
  onExpand: (groupKey: string) => void;
}) {
  const t = useT();
  const newChat = onNewChat && (
    <button type="button" className="acpmux-sidebar-action" onClick={onNewChat}>
      <Icon name="agent.chat.new" size={ROW_ICON} row />
      <span>{t("sidebar.newChat")}</span>
    </button>
  );
  const searching = query.trim() !== "";
  const { pinned, groups } = useMemo(() => sidebarSections(sessions, query), [sessions, query]);
  if (sessions.length === 0)
    return (
      <>
        {newChat}
        <div className="acpmux-sidebar-empty">{t("sidebar.noSessions")}</div>
      </>
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
    if (!composing) onQuery("");
  };
  return (
    <>
      {newChat}
      <search className="acpmux-sidebar-search">
        <label>
          <Icon name="search" size={ROW_ICON} row />
          <input
            type="search"
            aria-label={t("sidebar.search")}
            placeholder={t("sidebar.searchPlaceholder")}
            spellCheck={false}
            value={query}
            onChange={(event) => onQuery(event.target.value)}
            onKeyDown={onSearchKey}
          />
        </label>
      </search>
      {/* Always present, so a screen reader announces the text when it appears. */}
      <output className="acpmux-sidebar-empty">
        {pinned.length === 0 && groups.length === 0 ? t("sidebar.noMatches") : ""}
      </output>
      {pinned.length > 0 && (
        <section className="acpmux-sidebar-pinned" aria-label={t("sidebar.pinned")}>
          {labelled && (
            <div className="acpmux-sidebar-section" aria-hidden="true">
              {t("sidebar.pinned")}
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
        <section className="acpmux-sidebar-projects" aria-label={t("sidebar.projects")}>
          {labelled && (
            <div className="acpmux-sidebar-section" aria-hidden="true">
              {t("sidebar.projects")}
            </div>
          )}
          {groups.map((group) => {
            // A search shows every match, so it never hides rows behind "Show more".
            const { rows, hidden } = visibleSessions(group, searching || expanded.has(group.key), selectedId);
            const mark = groupMark(group, selectedId);
            return (
              <section className="acpmux-sidebar-group" key={group.key}>
                <div
                  className="acpmux-sidebar-project"
                  title={
                    group.host ? t("sidebar.folderOnHost", { folder: group.cwd ?? "", host: group.host }) : group.cwd
                  }
                >
                  <Icon name="folder" size={ROW_ICON} row />
                  <span>{group.label}</span>
                  {group.host && <small className="acpmux-sidebar-host">{group.host}</small>}
                  {mark && (
                    <span className={`acpmux-session-mark acpmux-session-mark-${mark}`} title={t(MARK_LABELS[mark])}>
                      {MARK_GLYPHS[mark]}
                      <span className="acpmux-hidden-label">{t(MARK_LABELS[mark])}</span>
                    </span>
                  )}
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
                    onClick={() => onExpand(group.key)}
                    aria-label={t("sidebar.showMoreHidden", { n: hidden })}
                  >
                    {t("sidebar.showMore")}
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
  const t = useT();
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
    <section aria-label={t(VIEW_TITLES[view])}>
      <h2 className="acpmux-sidebar-title">{t(VIEW_TITLES[view])}</h2>
      {rows.length === 0 ? (
        <div className="acpmux-sidebar-empty">{view === "pulls" ? t("sidebar.noPulls") : t("sidebar.nothing")}</div>
      ) : (
        <ul>
          {rows.map((session) => (
            <SessionRow
              key={session.sessionId}
              session={session}
              selected={session.sessionId === selectedId}
              onSelect={onSelect}
              flat
              trailing={shortAge(session.updatedAt, now, t)}
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
  groupHost,
  onSelect,
  flat,
  trailing,
}: {
  session: AcpmuxSessionEntry;
  selected: boolean;
  groupHost?: string;
  onSelect: (sessionId: string) => void;
  flat?: boolean;
  trailing?: string;
}) {
  const t = useT();
  const open = useContext(OpenSessions)?.has(session.sessionId);
  const mark = sessionMark(session, selected);
  const title = session.displayTitle || session.sessionId.slice(0, 8);
  const place = sessionPlace(session, groupHost);
  const placeLabel =
    place &&
    `${t(PLACE_LABELS[place.kind])} ${place.label}${place.branch ? `, ${t(PLACE_LABELS.branch)} ${place.branch}` : ""}`;
  return (
    <li>
      <button
        type="button"
        className={`acpmux-session-row${flat ? " is-flat" : ""}${selected ? " is-selected" : ""}${open ? " is-open" : ""}${session.status === "closed" ? " is-closed" : ""}`}
        aria-current={selected ? "true" : undefined}
        aria-label={
          mark || place || trailing || open
            ? [title, open && t("sidebar.alreadyOpen"), trailing, placeLabel, mark && t(MARK_LABELS[mark])]
                .filter(Boolean)
                .join(", ")
            : undefined
        }
        title={placeLabel ? `${title}\n${placeLabel}` : title}
        onClick={() => onSelect(session.sessionId)}
      >
        <span className="acpmux-session-row-title">{title}</span>
        {trailing && (
          <span className="acpmux-session-trailing" aria-hidden="true">
            {trailing}
          </span>
        )}
        {place && (
          <span className={`acpmux-session-place acpmux-session-place-${place.kind}`} aria-hidden="true">
            {PLACE_GLYPHS[place.kind]}
          </span>
        )}
        {mark ? (
          <span
            className={`acpmux-session-mark acpmux-session-mark-${mark}`}
            aria-hidden="true"
            title={t(MARK_LABELS[mark])}
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
