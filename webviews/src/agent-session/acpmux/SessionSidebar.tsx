import React, { createContext, memo, useContext, useEffect, useId, useMemo, useRef, useState } from "react";
import {
  filterSessions,
  groupMark,
  sessionMark,
  sessionPlace,
  sortByRecency,
  shortAge,
  sidebarSections,
  visibleSessions,
  type AcpmuxSessionEntry,
  type SessionMark,
} from "./sessionList";
import { type StringKey, useT } from "./i18n";

import { Icon } from "./icons/Icon";
import { rowIconSize } from "./icons/iconSize";
import { ContextMenu, type ContextMenuItem } from "../../ui/ContextMenu";
import { listRowKeyboardProps } from "../../ui/listRowKeyboard";
import { pressToOpen } from "../../ui/pressToOpen";
import { AnchoredCard } from "../../ui/Tooltip";
import { HOVER_INTENT, HoverGroup, useHoverIntent } from "../../ui/hoverIntent";
import { useSidebarPreviewVariant, type SidebarPreviewVariant } from "./sidebarPreview";

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

/** Sidebar previews are one warm hover-card group, so moving between rows does not replay the dwell. */
const sessionPreviewGroup = new HoverGroup(HOVER_INTENT.cardGrace);

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
  settledSessions = [],
  selectedId,
  openIds,
  onSelect,
  onNewChat,
  account,
  preview = false,
  previewVariant,
  groupProjects = false,
  onContinue,
  onSettle,
  onShowMoreSettled,
}: {
  sessions: AcpmuxSessionEntry[];
  /** Read-only history from the `_acpmux/chat_settled` seam. */
  settledSessions?: AcpmuxSessionEntry[];
  selectedId?: string;
  /** Sessions already open in a tab; their rows say so, and opening one jumps to it. */
  openIds?: ReadonlySet<string>;
  onSelect: (sessionId: string) => void;
  onNewChat?: () => void;
  account?: SidebarAccount;
  /** Preview features are on (`labs.previewFeatures`): show Pull requests and session hover cards. */
  preview?: boolean;
  /** DEV/NIGHTLY visual trial; defaults to the shared `card` treatment. */
  previewVariant?: SidebarPreviewVariant;
  /** Preserves project grouping as an option while keeping the default compact and ungrouped. */
  groupProjects?: boolean;
  onContinue?: (sessionIds: string[]) => void;
  onSettle?: (sessionIds: string[]) => void;
  onShowMoreSettled?: () => void;
}) {
  const t = useT();
  const activePreviewVariant = useSidebarPreviewVariant(previewVariant);
  const [picked, setView] = useState<SidebarView>("sessions");
  // Pull requests turned off while shown falls back to the session list, and stays there.
  const view = picked === "pulls" && !preview ? "sessions" : picked;
  useEffect(() => {
    if (!preview) setView((current) => (current === "pulls" ? "sessions" : current));
  }, [preview]);
  // Kept here so expanded projects and a search survive a trip to another rail view.
  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  const [query, setQuery] = useState("");
  const needsInput = useMemo(
    () => sessions.some((session) => sessionMark(session, session.sessionId === selectedId) === "input"),
    [sessions, selectedId],
  );
  return (
    <OpenSessions.Provider value={openIds}>
      <nav className="acpmux-sidebar" id="acpmux-sidebar" data-list-keyboard aria-label={t("sidebar.label")}>
        <div className="acpmux-rail" data-list-keyboard>
          <RailButton label={t("picker.newChat")} title={t("picker.newChat")} onClick={onNewChat} icon="home" />

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
                settledSessions={settledSessions}
                groupProjects={groupProjects}
                preview={preview}
                previewVariant={activePreviewVariant}
                onContinue={onContinue}
                onSettle={onSettle}
                onShowMoreSettled={onShowMoreSettled}
              />
            ) : (
              <FlatView
                view={view}
                sessions={sessions}
                selectedId={selectedId}
                onSelect={onSelect}
                preview={preview}
                previewVariant={activePreviewVariant}
              />
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
  const keyboard = listRowKeyboardProps(".acpmux-rail-button:not(:disabled)", (row) => row.click());
  return (
    <button
      {...keyboard}
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
  settledSessions,
  selectedId,
  onSelect,
  onNewChat,
  query,
  onQuery,
  expanded,
  onExpand,
  groupProjects,
  preview,
  previewVariant,
  onContinue,
  onSettle,
  onShowMoreSettled,
}: {
  sessions: AcpmuxSessionEntry[];
  settledSessions: AcpmuxSessionEntry[];
  selectedId?: string;
  onSelect: (sessionId: string) => void;
  onNewChat?: () => void;
  query: string;
  onQuery: (query: string) => void;
  expanded: Set<string>;
  onExpand: (groupKey: string) => void;
  groupProjects: boolean;
  preview: boolean;
  previewVariant: SidebarPreviewVariant;
  onContinue?: (sessionIds: string[]) => void;
  onSettle?: (sessionIds: string[]) => void;
  onShowMoreSettled?: () => void;
}) {
  const t = useT();
  const newChat = onNewChat && (
    <button type="button" className="acpmux-sidebar-action" onClick={onNewChat}>
      <Icon name="agent.chat.new" size={ROW_ICON} row />
      <span>{t("sidebar.newChat")}</span>
    </button>
  );
  const searching = query.trim() !== "";
  const { pinned, groups, active } = useMemo(
    () => sidebarSections(sessions, query, groupProjects),
    [sessions, query, groupProjects],
  );
  const settled = useMemo(() => sortByRecency(filterSessions(settledSessions, query)), [settledSessions, query]);
  const noMatches = pinned.length === 0 && active.length === 0 && settled.length === 0;
  if (sessions.length === 0 && settledSessions.length === 0)
    return (
      <>
        {newChat}
        <div className="acpmux-sidebar-empty">{t("sidebar.noSessions")}</div>
      </>
    );
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
      <output className="acpmux-sidebar-empty">{noMatches ? t("sidebar.noMatches") : ""}</output>
      {pinned.length > 0 && (
        <section className="acpmux-sidebar-pinned" aria-label={t("sidebar.pinned")}>
          <div className="acpmux-sidebar-section" aria-hidden="true">
            {t("sidebar.pinned")}
          </div>
          <ul>
            {pinned.map((session) => (
              <SessionRow
                key={session.sessionId}
                session={session}
                preview={preview}
                previewVariant={previewVariant}
                selected={session.sessionId === selectedId}
                onSelect={onSelect}
                section="active"
                onSettle={onSettle}
              />
            ))}
          </ul>
        </section>
      )}
      {active.length > 0 && !groupProjects && (
        <section className="acpmux-sidebar-active" aria-label={t("sidebar.active")}>
          <div className="acpmux-sidebar-section" aria-hidden="true">
            {t("sidebar.active")}
          </div>
          <ul>
            {active.map((session) => (
              <SessionRow
                key={session.sessionId}
                session={session}
                preview={preview}
                previewVariant={previewVariant}
                selected={session.sessionId === selectedId}
                onSelect={onSelect}
                section="active"
                onSettle={onSettle}
                flat
              />
            ))}
          </ul>
        </section>
      )}
      {groups.length > 0 && groupProjects && (
        <section className="acpmux-sidebar-projects" aria-label={t("sidebar.projects")}>
          <div className="acpmux-sidebar-section" aria-hidden="true">
            {t("sidebar.projects")}
          </div>
          {groups.map((group) => {
            // A search shows every match, so it never hides rows behind "Show more".
            const { rows, hidden } = visibleSessions(group, searching || expanded.has(group.key), selectedId);
            const mark = groupMark(group, selectedId);
            return (
              <section className="acpmux-sidebar-group" key={group.key}>
                <div className="acpmux-sidebar-project">
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
                      preview={preview}
                      previewVariant={previewVariant}
                      selected={session.sessionId === selectedId}
                      groupHost={group.host}
                      onSelect={onSelect}
                      section="active"
                      onSettle={onSettle}
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
      {/* With nothing matching, the line above says so once; an empty Settled would repeat it. */}
      {!noMatches && (
        <section className="acpmux-sidebar-settled" aria-label={t("sidebar.settled")}>
          <div className="acpmux-sidebar-section" aria-hidden="true">
            {t("sidebar.settled")}
          </div>
          {settled.length === 0 ? (
            <div className="acpmux-sidebar-empty">
              {settledSessions.length > 0 && query.trim() ? t("sidebar.noMatches") : t("sidebar.noSettled")}
            </div>
          ) : (
            <ul>
              {settled.map((session) => (
                <SessionRow
                  key={session.sessionId}
                  session={session}
                  preview={preview}
                  previewVariant={previewVariant}
                  selected={session.sessionId === selectedId}
                  onSelect={onSelect}
                  section="settled"
                  onContinue={onContinue}
                  flat
                />
              ))}
            </ul>
          )}
          {onShowMoreSettled && settled.length > 0 && (
            <button type="button" className="acpmux-sidebar-more" onClick={onShowMoreSettled}>
              {t("sidebar.showMore")}
            </button>
          )}
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
  preview,
  previewVariant,
}: {
  view: Exclude<SidebarView, "sessions">;
  sessions: AcpmuxSessionEntry[];
  selectedId?: string;
  onSelect: (sessionId: string) => void;
  preview: boolean;
  previewVariant: SidebarPreviewVariant;
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
              preview={preview}
              previewVariant={previewVariant}
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
  preview,
  previewVariant,
  selected,
  groupHost,
  onSelect,
  flat,
  trailing,
  section,
  onContinue,
  onSettle,
}: {
  session: AcpmuxSessionEntry;
  preview: boolean;
  previewVariant: SidebarPreviewVariant;
  selected: boolean;
  groupHost?: string;
  onSelect: (sessionId: string) => void;
  flat?: boolean;
  trailing?: string;
  section?: "active" | "settled";
  onContinue?: (sessionIds: string[]) => void;
  onSettle?: (sessionIds: string[]) => void;
}) {
  const t = useT();
  const open = useContext(OpenSessions)?.has(session.sessionId);
  const mark = sessionMark(session, selected);
  const title = session.displayTitle || session.sessionId.slice(0, 8);
  const place = sessionPlace(session, groupHost);
  const previewText = preview ? session.preview?.trim() : undefined;
  const previewId = useId();
  const previewIntent = useHoverIntent<HTMLElement>({ delay: HOVER_INTENT.cardDwell, group: sessionPreviewGroup });
  const { dismiss: dismissPreview } = previewIntent;
  const previewLeaveTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const [placedPreview, setPlacedPreview] = useState<HTMLElement | null>(null);
  useEffect(() => {
    if (previewIntent.shown) setPlacedPreview(previewIntent.shown);
  }, [previewIntent.shown]);
  useEffect(() => {
    if (!previewText) {
      clearTimeout(previewLeaveTimer.current);
      previewLeaveTimer.current = undefined;
      dismissPreview();
    }
  }, [dismissPreview, previewText]);
  useEffect(() => () => clearTimeout(previewLeaveTimer.current), []);
  const cancelPreviewLeave = () => {
    clearTimeout(previewLeaveTimer.current);
    previewLeaveTimer.current = undefined;
  };
  const hoverPreview = (anchor: HTMLElement, delay?: number) => {
    cancelPreviewLeave();
    previewIntent.hover(anchor, delay);
  };
  const leavePreviewRow = () => {
    cancelPreviewLeave();
    if (!previewIntent.shown) {
      previewIntent.hover(null);
      return;
    }
    previewLeaveTimer.current = setTimeout(() => {
      previewLeaveTimer.current = undefined;
      previewIntent.hover(null);
    }, HOVER_INTENT.cardGrace);
  };
  const leavePreviewCard = () => {
    cancelPreviewLeave();
    previewIntent.hover(null);
  };
  const dismissPreviewNow = () => {
    cancelPreviewLeave();
    dismissPreview();
  };
  const keyboard = listRowKeyboardProps(".acpmux-session-row", (row) => {
    const sessionId = row.dataset.sessionId;
    if (sessionId) onSelect(sessionId);
  });
  const placeLabel =
    place &&
    `${t(PLACE_LABELS[place.kind])} ${place.label}${place.branch ? `, ${t(PLACE_LABELS.branch)} ${place.branch}` : ""}`;
  const previewStatus = mark ? t(MARK_LABELS[mark]) : undefined;
  const menuItems: ContextMenuItem[] = [];
  if (section === "settled" && onContinue) {
    menuItems.push({
      id: "continue",
      label: t("sidebar.continue"),
      onSelect: () => onContinue([session.sessionId]),
    });
  }
  if (section === "active" && onSettle) {
    menuItems.push({
      id: "settle",
      label: t("sidebar.settle"),
      onSelect: () => onSettle([session.sessionId]),
    });
  }
  const row = (
    <button
      {...keyboard}
      type="button"
      data-session-id={session.sessionId}
      data-focus-ring="row"
      className={`acpmux-session-row${flat ? " is-flat" : ""}${selected ? " is-selected" : ""}${open ? " is-open" : ""}${session.status === "closed" ? " is-closed" : ""}`}
      aria-current={selected ? "true" : undefined}
      aria-describedby={previewText && previewIntent.shown ? previewId : undefined}
      aria-label={
        mark || place || trailing || open
          ? [title, open && t("sidebar.alreadyOpen"), trailing, placeLabel, mark && t(MARK_LABELS[mark])]
              .filter(Boolean)
              .join(", ")
          : undefined
      }
      onPointerEnter={(event) => previewText && hoverPreview(event.currentTarget)}
      onPointerLeave={leavePreviewRow}
      onPointerDown={dismissPreviewNow}
      // Opens on the press, as the native sidebar rows do; Enter and Space still click.
      {...pressToOpen(() => onSelect(session.sessionId))}
      onFocus={(event) => previewText && hoverPreview(event.currentTarget, 0)}
      onBlur={leavePreviewCard}
      // ui-allow: Escape dismisses this row's anchored preview; arrow/Home/End navigation stays in the shared helper.
      onKeyDown={(event) => {
        keyboard.onKeyDown?.(event);
        if (event.key === "Escape") dismissPreviewNow();
      }}
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
  );
  return (
    <li>
      {menuItems.length > 0 ? <ContextMenu items={menuItems}>{row}</ContextMenu> : row}
      {previewText && placedPreview && (
        <AnchoredCard
          id={previewId}
          anchor={placedPreview}
          open={previewIntent.shown !== null}
          side="inline-end"
          className={`acpmux-session-preview acpmux-session-preview-${previewVariant}`}
          instant={previewIntent.instant}
          onPointerEnter={cancelPreviewLeave}
          onPointerLeave={leavePreviewCard}
        >
          <div className="acpmux-session-preview-title">{title}</div>
          <div className="acpmux-session-preview-copy">{previewText}</div>
          {(previewStatus || placeLabel) && (
            <div className="acpmux-session-preview-meta">
              {previewStatus && (
                <span className={`acpmux-session-preview-status acpmux-session-mark-${mark}`}>
                  {mark && MARK_GLYPHS[mark]}
                  {previewStatus}
                </span>
              )}
              {placeLabel && (
                <span className="acpmux-session-preview-place">
                  {place && PLACE_GLYPHS[place.kind]}
                  {placeLabel}
                </span>
              )}
            </div>
          )}
        </AnchoredCard>
      )}
    </li>
  );
});
