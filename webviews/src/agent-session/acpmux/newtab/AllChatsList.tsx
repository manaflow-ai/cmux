// All chats on the New Tab page (Lawrence 2026-10-10, cx-n0i9; the sidebar has no All chats
// section any more): every coding agent chat on this computer, newest first, searchable. The
// list is virtualized (only the rows near the viewport are in the DOM) and paged: the host asks
// the daemon for one page at a time (`chats.page` -> `_acpmux/chats {query, limit, cursor}`), and
// the next page loads when its loader row scrolls into view. One click opens the chat in a new
// workspace with the agent pane (the host's Open Chat path); Open in terminal is in the row's
// right-click menu. The row look follows the TEMPORARY design picker (`sidebar.allChats.design`).
// With `onBring` (the History page, cx-zlnl) rows also select: Cmd/Ctrl-click toggles one,
// Shift-click a range, Enter opens the selection, and the menu brings it into active sessions.
// Projects (cx-ncc.66, Claude parity) shows the same chats grouped under their project folder.
// Filter (cx-htpk0, Claude desktop parity) narrows the list to the live chats that are working or
// wait on the user, or to the finished ones: live chats at rest, then every indexed chat.
import React, { memo, useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";

import { ContextMenu } from "../../../ui/ContextMenu";

import { VirtualList } from "../../../ui/VirtualList";
import { useT } from "../i18n";

import { AgentMark } from "../NewTabPage";
import { ageLabel, nextAgeLabel } from "../newTabModel";
import { useNt } from "./strings";
import { useLabelClock } from "../clock";
import { ChatFilterMenu, type ChatStatusFilter } from "./ChatFilterMenu";
import { AllChatsLoading } from "./AllChatsLoading";
import { useLasting } from "../../../ui/lasting";
import {
  type AllChatsRow,
  type LoadChatsPage,
  CHATS_READ_CEILING_MS,
  type ChatProject,
  projectGroups,
  useChatPages,
  useChatOpenFeedback,
  watchable,
} from "./allChatsListModel";
import { pressToOpen } from "../../../ui/pressToOpen";
import { WithFacts } from "../chips/FactsHoverCard";
import { IllustratedEmpty } from "../../../ui/EmptyState/IllustratedEmpty";
import { experimentArm } from "../../../experiments/experiment";
import { emptyStateContext } from "../emptyStateContext.experiment";
/// A chat that is running or waits on the user (acpmux's own sessions): it leads the list with
/// its state where the age would be.
export type ActiveChat = {
  id: string;
  title: string;
  harness?: string;
  state: "input" | "running" | "failed" | "error" | "unread" | "idle";
  label: string;
};

/// The header's Filter: All shows the list as it always was. Only live chats carry a state, so
/// Working and Needs input show live chats alone, and Done adds the indexed chats after them.
/// A failed or broken turn waits on the user as much as a question does.
const FILTER_STATES: Record<Exclude<ChatStatusFilter, "all">, ReadonlySet<ActiveChat["state"]>> = {
  working: new Set(["running"]),
  input: new Set(["input", "failed", "error"]),
  done: new Set(["unread", "idle"]),
};

const ROW_HEIGHT = 30;

/// One row of the list: a project's header (Projects only) or a chat.
type ListEntry = { kind: "project"; project: ChatProject; open: boolean } | { kind: "chat"; row: AllChatsRow };

function listEntries(rows: AllChatsRow[], view: "chats" | "projects", folded: ReadonlySet<string>): ListEntry[] {
  if (view === "chats") return rows.map((row) => ({ kind: "chat", row }));
  return projectGroups(rows).flatMap((project): ListEntry[] => {
    const open = !folded.has(project.key);
    return [
      { kind: "project", project, open },
      ...(open ? project.rows.map((row): ListEntry => ({ kind: "chat", row })) : []),
    ];
  });
}

const NO_KEYS: string[] = [];

/// Selection by Cmd/Ctrl-click (toggle) and Shift-click (the range from the last clicked row),
/// in list order. A new query starts with nothing selected. `click`, `collapse` and `clear` keep
/// their identity (they read the rows of the last render), so a row that takes them stays memoized;
/// `has` is a Set built once per selection change, so a row asks for its own key in O(1).
function useSelection(rows: AllChatsRow[], query: string) {
  const [selected, setSelected] = useState<string[]>(NO_KEYS);
  const anchor = useRef<string | undefined>(undefined);
  const shown = useRef(rows);
  useLayoutEffect(() => {
    shown.current = rows;
  });
  const clear = useCallback(() => setSelected((current) => (current.length === 0 ? current : NO_KEYS)), []);
  useEffect(() => {
    clear();
    anchor.current = undefined;
  }, [query, clear]);
  /// True when the click selected (a modifier was held); false leaves it to open.
  const click = useCallback(
    (event: React.MouseEvent, key: string): boolean => {
      if (event.shiftKey) {
        const rows = shown.current;
        const from = rows.findIndex((row) => row.key === anchor.current);
        const to = rows.findIndex((row) => row.key === key);
        if (from < 0 || to < 0) {
          anchor.current = key;
          setSelected([key]);
        } else {
          setSelected(rows.slice(Math.min(from, to), Math.max(from, to) + 1).map((row) => row.key));
        }
        return true;
      }
      if (event.metaKey || event.ctrlKey) {
        anchor.current = key;
        setSelected((current) => (current.includes(key) ? current.filter((k) => k !== key) : [...current, key]));
        return true;
      }
      anchor.current = key;
      clear();
      return false;
    },
    [clear],
  );
  /// A plain open of `key`: the selection collapses and `key` anchors the next Shift-click.
  const collapse = useCallback(
    (key: string) => {
      anchor.current = key;
      clear();
    },
    [clear],
  );
  const has = useMemo(() => new Set(selected), [selected]);
  return { selected, has, click, collapse, clear };
}

/// A chat's age ("5m") on the shared minute clock (clock.ts useLabelClock): it wakes only at the
/// minute its own words change, and renders nothing but itself; the row never takes the clock.
function ChatAge({ at }: { at: number }) {
  const t = useT();
  const now = useLabelClock(at, nextAgeLabel);
  const age = ageLabel(at, now, t);
  return age ? <span className="nt-all-meta">{age}</span> : null;
}

type ChatRowProps = {
  chatKey: string;
  harness: string;
  title: string | undefined;
  cwd: string | undefined;
  updatedAt: number;
  index: number;
  setSize: number;
  style: React.CSSProperties;
  showProject: boolean;
  showAge: boolean;
  /// A fixed clock (tests, gallery); unset, the age reads the shared clock itself (ChatAge).
  now: number | undefined;
  selected: boolean;
  busy: boolean;
  onPress(key: string): void;
  onClickRow(event: React.MouseEvent, key: string): void;
  deferPress(key: string): boolean;
  onMenu(key: string): void;
};

/// One chat of the list. Every prop is a value of this chat or a callback that keeps its identity
/// (VirtualList hands the same frozen `style` while the row's place holds), so selecting, opening
/// or updating another chat, a scroll step and a clock tick render no other row.
const ChatRow = memo(function ChatRow({
  chatKey,
  harness,
  title: given,
  cwd,
  updatedAt,
  index,
  setSize,
  style,
  showProject,
  showAge,
  now,
  selected,
  busy,
  onPress,
  onClickRow,
  deferPress,
  onMenu,
}: ChatRowProps) {
  const t = useT();
  const title = given ?? t("sidebar.newChat");
  // The project names an untitled chat apart from the others ("New chat · cmux").
  const project = cwd ? cwd.split("/").filter(Boolean).pop() : undefined;
  const age = showAge && now !== undefined ? ageLabel(updatedAt, now, t) : undefined;
  return (
    <div
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- a virtualized row (absolute, transformed), not a flow <li>
      role="listitem"
      className="nt-all-item"
      style={style}
      aria-posinset={index + 1}
      aria-setsize={setSize}
      onContextMenuCapture={() => onMenu(chatKey)}
    >
      <button
        type="button"
        className="nt-all-row"
        data-focus-ring="row"
        data-untitled={given ? undefined : true}
        data-selected={selected ? true : undefined}
        aria-busy={busy}
        // A plain press opens at once; a Cmd/Shift-click selects on the release, and a press on a row
        // of a multi-selection waits for the release (the Finder rule).
        {...pressToOpen(() => onPress(chatKey), {
          deferPress: () => deferPress(chatKey),
          onClick: (event) => onClickRow(event, chatKey),
        })}
      >
        <span className="nt-all-glyph">
          <AgentMark harness={harness} />
        </span>
        <span className="nt-all-title">{title}</span>
        {project && showProject && (
          <WithFacts facts={[{ value: cwd ?? "", code: true }]}>
            {(facts) => (
              <span {...facts} className="nt-all-project">
                {project}
              </span>
            )}
          </WithFacts>
        )}
        {age && <span className="nt-all-meta">{age}</span>}
        {showAge && now === undefined && updatedAt ? <ChatAge at={updatedAt} /> : null}
      </button>
    </div>
  );
});

/// A project's header (Projects only); a press folds or unfolds its chats.
const ProjectRow = memo(function ProjectRow({
  projectKey,
  label,
  chats,
  open,
  index,
  setSize,
  style,
  onToggle,
}: {
  projectKey: string;
  label: string | undefined;
  chats: number;
  open: boolean;
  index: number;
  setSize: number;
  style: React.CSSProperties;
  onToggle(key: string, open: boolean): void;
}) {
  const nt = useNt();
  return (
    <div
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- a virtualized row (absolute, transformed), not a flow <li>
      role="listitem"
      className="nt-all-item"
      style={style}
      aria-posinset={index + 1}
      aria-setsize={setSize}
    >
      <button
        type="button"
        className="nt-all-group"
        data-focus-ring="row"
        aria-expanded={open}
        onClick={() => onToggle(projectKey, open)}
      >
        <svg className="nt-all-group-chevron" viewBox="0 0 16 16" width="12" height="12" aria-hidden="true">
          <path d="m6 4 4 4-4 4" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
        </svg>
        <span className="nt-all-group-name">{label ?? nt("noProject")}</span>
        <span className="nt-all-group-count">{chats}</span>
      </button>
    </div>
  );
});

/// A live chat's row, a leader's too: its right-click menu is Open, as its click (cx-2lm4). It takes
/// the chat's values, not the chat: the page builds new chat objects on each of its renders.
const LiveChatRow = memo(function LiveChatRow({
  id,
  title,
  harness,
  state,
  label,
  onOpen,
}: {
  id: string;
  title: string;
  harness: string | undefined;
  state: ActiveChat["state"];
  label: string;
  onOpen(id: string): void;
}) {
  const nt = useNt();
  return (
    <li>
      <ContextMenu className="nt-row-host" items={[{ id: "open", label: nt("row.open"), onSelect: () => onOpen(id) }]}>
        <button
          type="button"
          className="nt-all-row"
          data-focus-ring="row"
          data-state={state}
          {...pressToOpen(() => onOpen(id))}
        >
          <span className="nt-all-glyph">
            <AgentMark harness={harness} />
          </span>
          <span className="nt-all-title">{title}</span>
          <span className="nt-all-state">{label}</span>
        </button>
      </ContextMenu>
    </li>
  );
});

export function AllChatsList({
  load,
  onOpen,
  active = [],
  leads = [],
  onOpenActive,
  onOpenInTerminal,
  onViewOnly,
  onBring,
  now: fixedNow,
  scrollParent,
}: {
  load: LoadChatsPage;
  onOpen(key: string): unknown;
  active?: ActiveChat[];
  /// The leaders (leads.ts): every live chat other chats report to, listed once above the live
  /// chats; a click opens it as a live chat's does.
  leads?: ActiveChat[];
  onOpenActive?(id: string): void;
  onOpenInTerminal?(key: string): void;
  /// View Only: a Claude Code or Codex chat in a tab that shows it and follows the app that runs
  /// it, without running it, until Take Over (`chats.watch`, the same opener as `cmux agent view`).
  onViewOnly?(key: string): void;
  /// Rows select, and the menu's Bring into Active Sessions opens the selection (cx-zlnl).
  onBring?(keys: string[]): unknown;
  now?: number;
  /** New Tab scrolls the whole page; History retains its own list viewport. */
  scrollParent?: string;
}) {
  const t = useT();
  const nt = useNt();
  // Ages read the shared clock (clock.ts) in each row's ChatAge, as the New Tab cards: one age for
  // one chat on every page. `fixedNow` (tests, gallery) holds every age still.
  const { state, fetchPage, search } = useChatPages(load);
  const openFeedback = useChatOpenFeedback(onOpen, onBring);
  const menuKey = useRef<string | undefined>(undefined);
  const [menuTarget, setMenuTarget] = useState<string | undefined>(undefined);
  const { rows, nextCursor } = state;
  // The skeleton holds the rows' layout while a read is out (no text, no shift when it lands); a read
  // that never answers is said as the failure line, with Try again, once it passes the ceiling.
  const waiting = rows.length === 0 && (!state.loaded || state.loading || (!state.ready && !state.failed));
  const unanswered = useLasting(rows.length === 0 && (!state.loaded || state.loading), CHATS_READ_CEILING_MS);
  const [view, setView] = useState<"chats" | "projects">("chats");
  const [filter, setFilter] = useState<ChatStatusFilter>("all");
  // Working and Needs input are live chats only; the indexed rows are finished chats.
  const indexed = filter === "all" || filter === "done";
  const query = state.query.trim().toLowerCase();
  const contextual = experimentArm(emptyStateContext) === "contextual";
  const emptySearch =
    state.query.trim() && contextual ? (
      <IllustratedEmpty
        className="nt-chats-empty-state"
        layout="beside"
        line={t("emptyState.chatMatches", { query: state.query.trim() })}
        action={{ label: t("emptyState.clearSearch"), kind: "link", onClick: () => search("") }}
      />
    ) : (
      <p className="nt-chats-empty">{t("sidebar.noMatches")}</p>
    );
  // A search hides live chats under All, as before; a live-only filter searches their titles.
  const activeShown =
    filter === "all"
      ? state.query
        ? []
        : active
      : active.filter(
          (chat) =>
            FILTER_STATES[filter].has(chat.state) &&
            (indexed ? !state.query : chat.title.toLowerCase().includes(query)),
        );
  // The leaders show under All with no search; a filter or a search is about the chats.
  const leadsShown = filter === "all" && !state.query ? leads : [];
  // The callbacks rows take keep their identity and read this render's values when called.
  const latest = useRef({ openFeedback, onOpenActive, onBring, selection: NO_KEYS as string[] });
  const openActive = useCallback((id: string) => latest.current.onOpenActive?.(id), []);
  const liveRow = (chat: ActiveChat) => (
    <LiveChatRow
      key={chat.id}
      id={chat.id}
      title={chat.title}
      harness={chat.harness}
      state={chat.state}
      label={chat.label}
      onOpen={openActive}
    />
  );
  const [folded, setFolded] = useState<ReadonlySet<string>>(() => new Set());
  const entries = listEntries(rows, view, folded);
  // A Shift-click range runs over the chats as the list shows them.
  const shown = entries.flatMap((entry) => (entry.kind === "chat" ? [entry.row] : []));
  const selection = useSelection(shown, state.query);
  // The menu acts on the selection when the clicked row is in it, else on that row.
  const menuKeys = menuTarget ? (selection.has.has(menuTarget) ? selection.selected : [menuTarget]) : [];
  // While rows are selected, Enter opens them and Escape clears them. The page listens, not the
  // rows: WebKit does not focus a button on click, so after Cmd/Shift-click no row has focus.
  const { selected, clear, collapse, click } = selection;
  useLayoutEffect(() => {
    latest.current = { openFeedback, onOpenActive, onBring, selection: selected };
  });
  const pressChat = useCallback(
    (key: string) => {
      collapse(key);
      latest.current.openFeedback.open(key);
    },
    [collapse],
  );
  const clickChat = useCallback(
    (event: React.MouseEvent, key: string) => {
      if (latest.current.onBring && click(event, key)) return;
      latest.current.openFeedback.open(key);
    },
    [click],
  );
  const deferChatPress = useCallback((key: string) => {
    const { onBring: bringing, selection: keys } = latest.current;
    return !!bringing && keys.length > 1 && keys.includes(key);
  }, []);
  const chatMenu = useCallback((key: string) => {
    menuKey.current = key;
  }, []);
  const toggleProject = useCallback(
    (key: string, open: boolean) => {
      // A folded chat cannot stay selected: Enter or Bring would act on rows out of sight.
      clear();
      setFolded((current) => {
        const next = new Set(current);
        if (open) next.add(key);
        else next.delete(key);
        return next;
      });
    },
    [clear],
  );
  useEffect(() => {
    if (!onBring || selected.length === 0) return;
    const onKey = (event: KeyboardEvent) => {
      const target = event.target as HTMLElement | null;
      // Let focused controls keep their native keyboard action. In particular, the inline
      // later-page retry is a button: swallowing Enter here would open the current selection
      // instead of retrying the failed page.
      const control = target?.closest("button, input, textarea, select, a, [role=menu]");
      if (event.defaultPrevented || (control && !control.classList.contains("nt-all-row"))) return;
      if (event.key === "Enter") {
        event.preventDefault();
        openFeedback.bring(selected);
        clear();
      } else if (event.key === "Escape") {
        event.preventDefault();
        clear();
      }
    };
    // ui-allow: page-wide Enter/Escape for a selection; WebKit leaves no row focused after a click
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [onBring, selected, clear, openFeedback]);
  // With every project folded nothing scrolls the loader away: it would fetch page after page.
  const pages = view === "chats" || entries.some((entry) => entry.kind === "chat");
  const count = entries.length + (nextCursor && pages ? 1 : 0);
  const loadMore = useCallback(
    (element: HTMLElement | null) => {
      if (element && nextCursor) fetchPage(state.query, nextCursor);
    },
    [fetchPage, nextCursor, state.query],
  );
  const renderRow = (index: number, style: React.CSSProperties) => {
    const entry = entries[index];
    if (!entry) {
      const failedPage = nextCursor !== undefined && state.failedCursor === nextCursor;
      if (failedPage) {
        return (
          <output key={`more-${nextCursor}`} className="nt-all-item nt-chats-failed" style={style}>
            {nt("chatsLoadFailed")}
            <button
              type="button"
              className="nt-chats-retry"
              disabled={state.loading}
              onClick={() => fetchPage(state.query, nextCursor)}
            >
              {t("picker.tryAgain")}
            </button>
          </output>
        );
      }
      return <div key={`more-${nextCursor}`} ref={loadMore} className="nt-all-item is-loader" style={style} />;
    }
    if (entry.kind === "project") {
      const { project, open } = entry;
      return (
        <ProjectRow
          key={`project-${project.key}`}
          projectKey={project.key}
          label={project.label}
          chats={project.rows.length}
          open={open}
          index={index}
          setSize={count}
          style={style}
          onToggle={toggleProject}
        />
      );
    }
    const row = entry.row;
    return (
      <ChatRow
        key={row.key}
        chatKey={row.key}
        harness={row.harness}
        title={row.title}
        cwd={row.cwd}
        updatedAt={row.updatedAt}
        index={index}
        setSize={count}
        style={style}
        showProject={state.design !== "quiet" && view === "chats"}
        showAge={state.design !== "quiet"}
        now={fixedNow}
        selected={selection.has.has(row.key)}
        busy={openFeedback.opening === row.key}
        onPress={pressChat}
        onClickRow={clickChat}
        deferPress={deferChatPress}
        onMenu={chatMenu}
      />
    );
  };
  const items = [
    ...(onBring
      ? [
          {
            id: "bring",
            label: nt("bringIntoActive"),
            disabled: menuKeys.length === 0,
            onSelect: () => {
              openFeedback.bring(menuKeys);
              selection.clear();
            },
          },
        ]
      : []),
    ...(onOpenInTerminal
      ? [
          {
            id: "terminal",
            label: t("shell.openInTerminal"),
            disabled: !menuTarget,
            onSelect: () => menuTarget && onOpenInTerminal(menuTarget),
          },
        ]
      : []),
    ...(onViewOnly
      ? [
          {
            id: "viewOnly",
            label: nt("viewOnly"),
            disabled: !menuTarget || !watchable(menuTarget),
            onSelect: () => menuTarget && watchable(menuTarget) && onViewOnly(menuTarget),
          },
        ]
      : []),
  ];
  return (
    <section className="nt-all" aria-label={nt("chats")}>
      <header className="nt-chats-head">
        {(["chats", "projects"] as const).map((choice) => (
          <button
            key={choice}
            type="button"
            className={`nt-chats-tab${view === choice ? " is-selected" : ""}`}
            aria-pressed={view === choice}
            onClick={() => {
              selection.clear();
              setView(choice);
            }}
          >
            {nt(choice)}
          </button>
        ))}
        <ChatFilterMenu
          filter={filter}
          onFilter={(next) => {
            selection.clear();
            setFilter(next);
          }}
        />
        <label className="nt-all-search">
          <svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true">
            <circle cx="7" cy="7" r="4.5" fill="none" stroke="currentColor" strokeWidth="1.4" />
            <path d="m10.5 10.5 3 3" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
          </svg>
          <input
            type="search"
            value={state.query}
            placeholder={t("sidebar.searchPlaceholder")}
            aria-label={t("sidebar.search")}
            onChange={(event) => search(event.currentTarget.value)}
          />
        </label>
      </header>
      {openFeedback.failure && (
        <div className="nt-chats-empty nt-chats-failed" role="alert">
          {openFeedback.failure.message}
          {openFeedback.failure.key && (
            <button
              type="button"
              className="nt-chats-retry"
              onClick={() => {
                const key = openFeedback.failure?.key;
                if (key) openFeedback.open(key);
              }}
            >
              {t("picker.tryAgain")}
            </button>
          )}
        </div>
      )}
      {leadsShown.length > 0 && (
        <ul className="nt-all-active nt-all-leads" aria-label={nt("leads")}>
          <li className="nt-all-leads-head" aria-hidden="true">
            <span className="nt-all-group-name">{nt("leads")}</span>
            <span className="nt-all-group-count">{leadsShown.length}</span>
          </li>
          {leadsShown.map(liveRow)}
        </ul>
      )}
      {activeShown.length > 0 && (
        <ul className="nt-all-active" aria-label={t("sidebar.active")}>
          {activeShown.map(liveRow)}
        </ul>
      )}
      {!indexed ? (
        activeShown.length === 0 &&
        (state.query.trim() ? emptySearch : <p className="nt-chats-empty">{t("sidebar.noMatches")}</p>)
      ) : waiting && !unanswered ? (
        <AllChatsLoading rowHeight={ROW_HEIGHT} design={state.design} view={view} />
      ) : (state.loaded || unanswered) && rows.length === 0 ? (
        state.failed || unanswered ? (
          <output className="nt-chats-empty nt-chats-failed">
            {nt("chatsLoadFailed")}
            <button
              type="button"
              className="nt-chats-retry"
              // A read past the ceiling is still in flight: Try again starts a new one over it.
              disabled={state.loading && !unanswered}
              onClick={() => fetchPage(state.query, undefined)}
            >
              {t("picker.tryAgain")}
            </button>
          </output>
        ) : (
          state.ready && (state.query.trim() ? emptySearch : <p className="nt-chats-empty">{nt("noChats")}</p>)
        )
      ) : (
        <ContextMenu className="nt-all-host" items={items} onOpen={() => setMenuTarget(menuKey.current)}>
          <div className="nt-all-scroll" onContextMenuCapture={() => (menuKey.current = undefined)}>
            <VirtualList
              className="nt-all-list"
              scrollParent={scrollParent}
              // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- VirtualList's role prop, its scroller is a div
              role="list"
              label={nt("allChats")}
              count={count}
              estimateSize={() => ROW_HEIGHT}
              overscan={10}
              renderRow={renderRow}
            />
          </div>
        </ContextMenu>
      )}
    </section>
  );
}
