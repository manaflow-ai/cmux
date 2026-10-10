// All chats on the New Tab page (Lawrence 2026-10-10, cx-n0i9; the sidebar has no All chats
// section any more): every coding agent chat on this computer, newest first, searchable. The
// list is virtualized (only the rows near the viewport are in the DOM) and paged: the host asks
// the daemon for one page at a time (`chats.page` -> `_acpmux/chats {query, limit, cursor}`), and
// the next page loads when its loader row scrolls into view. One click opens the chat in a new
// workspace with the agent pane (the host's Open Chat path); Open in terminal is in the row's
// right-click menu. The row look follows the TEMPORARY design picker (`sidebar.allChats.design`).
// With `onBring` (the History page, cx-zlnl) rows also select: Cmd/Ctrl-click toggles one,
// Shift-click a range, Enter opens the selection, and the menu brings it into active sessions.
import React, { useCallback, useEffect, useRef, useState } from "react";
import { ContextMenu } from "../../../ui/ContextMenu";
import { VirtualList } from "../../../ui/VirtualList";
import { useT } from "../i18n";
import { AgentMark, ageLabel } from "../NewTabPage";
import { useNt } from "./strings";

export type AllChatsRow = { key: string; harness: string; title?: string; cwd?: string; updatedAt: number };
export type AllChatsDesign = "quiet" | "age" | "project";
/// A chat that is running or waits on the user (acpmux's own sessions): it leads the list with
/// its state where the age would be.
export type ActiveChat = {
  id: string;
  title: string;
  harness?: string;
  state: "input" | "running" | "error" | "unread" | "idle";
  label: string;
};

export type AllChatsPage = {
  chats: AllChatsRow[];
  nextCursor?: string;
  ready?: boolean;
  enabled?: boolean;
  design?: string;
};

/// The host's `chats.page`; rejects or resolves undefined when the daemon cannot answer.
export type LoadChatsPage = (params: {
  query?: string;
  cursor?: string;
  limit: number;
}) => Promise<AllChatsPage | undefined>;

const PAGE = 100;
const ROW_HEIGHT = 34;

type State = {
  query: string;
  rows: AllChatsRow[];
  nextCursor?: string;
  loading: boolean;
  loaded: boolean;
  /// The daemon's index has finished its first scan (`ready`); before that an empty page is not "No chats".
  ready: boolean;
  design: AllChatsDesign;
};

const initial: State = { query: "", rows: [], loading: false, loaded: false, ready: false, design: "age" };

function design(value: unknown): AllChatsDesign | undefined {
  return value === "quiet" || value === "age" || value === "project" ? value : undefined;
}

function rowsOf(page: AllChatsPage | undefined): AllChatsRow[] {
  if (!page || !Array.isArray(page.chats)) return [];
  return page.chats.filter((row) => row && typeof row.key === "string" && typeof row.harness === "string");
}

/// The pages of one query: a new query starts over at the first page (its old cursor is dropped
/// at once, so no page of the old query is asked for again); a reply for an older query is
/// dropped (latest wins). `load` may change identity on every parent render: the list keeps the
/// latest one in a ref, so a parent render never restarts the list.
function useChatPages(load: LoadChatsPage) {
  const [state, setState] = useState<State>(initial);
  const latestLoad = useRef(load);
  latestLoad.current = load;
  const generation = useRef(0);
  const inFlight = useRef<string | undefined>(undefined);
  const fetchPage = useCallback((query: string, cursor: string | undefined) => {
    const ticket = cursor ? generation.current : ++generation.current;
    const marker = `${ticket}:${cursor ?? ""}`;
    if (inFlight.current === marker) return;
    inFlight.current = marker;
    setState((s) => (cursor ? { ...s, loading: true } : { ...s, query, nextCursor: undefined, loading: true }));
    void latestLoad
      .current({ ...(query ? { query } : {}), ...(cursor ? { cursor } : {}), limit: PAGE })
      .catch(() => undefined)
      .then((page) => {
        if (ticket !== generation.current) return;
        if (inFlight.current === marker) inFlight.current = undefined;
        setState((s) => {
          // A failed page keeps the cursor, so the loader row asks again when it comes back into view.
          if (!page) return { ...s, loading: false, loaded: true, ...(cursor ? { nextCursor: cursor } : {}) };
          const fresh = rowsOf(page);
          const known = new Set(s.rows.map((row) => row.key));
          const rows = cursor ? [...s.rows, ...fresh.filter((row) => !known.has(row.key))] : fresh;
          return {
            ...s,
            rows,
            nextCursor: page.nextCursor && fresh.length > 0 ? page.nextCursor : undefined,
            loading: false,
            loaded: true,
            ready: page.ready !== false,
            design: design(page.design) ?? s.design,
          };
        });
      });
  }, []);
  // The first page when the list mounts (the page is a fresh view each time it shows).
  useEffect(() => {
    fetchPage("", undefined);
  }, [fetchPage]);
  return { state, fetchPage };
}

/// Selection by Cmd/Ctrl-click (toggle) and Shift-click (the range from the last clicked row),
/// in list order. A new query starts with nothing selected.
function useSelection(rows: AllChatsRow[], query: string) {
  const [selected, setSelected] = useState<string[]>([]);
  const anchor = useRef<string | undefined>(undefined);
  useEffect(() => {
    setSelected([]);
    anchor.current = undefined;
  }, [query]);
  /// True when the click selected (a modifier was held); false leaves it to open.
  const click = (event: React.MouseEvent, key: string): boolean => {
    if (event.shiftKey) {
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
    setSelected([]);
    return false;
  };
  const clear = useCallback(() => setSelected([]), []);
  return { selected, click, clear };
}

export function AllChatsList({
  load,
  onOpen,
  active = [],
  onOpenActive,
  onOpenInTerminal,
  onBring,
  now = Date.now(),
}: {
  load: LoadChatsPage;
  onOpen(key: string): void;
  active?: ActiveChat[];
  onOpenActive?(id: string): void;
  onOpenInTerminal?(key: string): void;
  /// Rows select, and the menu's Bring into Active Sessions opens the selection (cx-zlnl).
  onBring?(keys: string[]): void;
  now?: number;
}) {
  const t = useT();
  const nt = useNt();
  const { state, fetchPage } = useChatPages(load);
  const menuKey = useRef<string | undefined>(undefined);
  const [menuTarget, setMenuTarget] = useState<string | undefined>(undefined);
  const { rows, nextCursor } = state;
  const selection = useSelection(rows, state.query);
  // The menu acts on the selection when the clicked row is in it, else on that row.
  const menuKeys = menuTarget ? (selection.selected.includes(menuTarget) ? selection.selected : [menuTarget]) : [];
  // While rows are selected, Enter opens them and Escape clears them. The page listens, not the
  // rows: WebKit does not focus a button on click, so after Cmd/Shift-click no row has focus.
  const { selected, clear } = selection;
  useEffect(() => {
    if (!onBring || selected.length === 0) return;
    const onKey = (event: KeyboardEvent) => {
      const target = event.target as HTMLElement | null;
      if (event.defaultPrevented || target?.closest("input, textarea, [role=menu]")) return;
      if (event.key === "Enter") {
        event.preventDefault();
        onBring(selected);
        clear();
      } else if (event.key === "Escape") {
        event.preventDefault();
        clear();
      }
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [onBring, selected, clear]);
  const count = rows.length + (nextCursor ? 1 : 0);
  const loadMore = useCallback(
    (element: HTMLElement | null) => {
      if (element && nextCursor) fetchPage(state.query, nextCursor);
    },
    [fetchPage, nextCursor, state.query],
  );
  const renderRow = (index: number, style: React.CSSProperties) => {
    const row = rows[index];
    if (!row) return <div key={`more-${nextCursor}`} ref={loadMore} className="nt-all-item is-loader" style={style} />;
    const title = row.title ?? t("sidebar.newChat");
    // The project names an untitled chat apart from the others ("New chat · cmux").
    const project = row.cwd ? row.cwd.split("/").filter(Boolean).pop() : undefined;
    const age = state.design === "quiet" ? undefined : ageLabel(row.updatedAt, now, t);
    return (
      <div
        key={row.key}
        // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- a virtualized row (absolute, transformed), not a flow <li>
        role="listitem"
        className="nt-all-item"
        style={style}
        aria-posinset={index + 1}
        aria-setsize={count}
        onContextMenuCapture={() => (menuKey.current = row.key)}
      >
        <button
          type="button"
          className="nt-all-row"
          data-untitled={row.title ? undefined : true}
          data-selected={selection.selected.includes(row.key) ? true : undefined}
          title={row.cwd ? `${title}\n${row.cwd}` : title}
          onClick={(event) => {
            if (onBring && selection.click(event, row.key)) return;
            onOpen(row.key);
          }}
        >
          <span className="nt-all-glyph">
            <AgentMark harness={row.harness} />
          </span>
          <span className="nt-all-title">{title}</span>
          {project && state.design !== "quiet" && <span className="nt-all-project">{project}</span>}
          {age && <span className="nt-all-meta">{age}</span>}
        </button>
      </div>
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
              onBring(menuKeys);
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
  ];
  return (
    <section className="nt-all" aria-label={nt("chats")}>
      <header className="nt-chats-head">
        <span className="nt-chats-tab is-selected">{nt("chats")}</span>
        <label className="nt-all-search">
          <svg viewBox="0 0 16 16" width="13" height="13" aria-hidden="true">
            <circle cx="7" cy="7" r="4.5" fill="none" stroke="currentColor" strokeWidth="1.4" />
            <path d="m10.5 10.5 3 3" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
          </svg>
          <input
            type="search"
            value={state.query}
            placeholder={t("sidebar.searchPlaceholder")}
            aria-label={t("sidebar.search")}
            onChange={(event) => fetchPage(event.currentTarget.value, undefined)}
          />
        </label>
      </header>
      {!state.query && active.length > 0 && (
        <ul className="nt-all-active" aria-label={t("sidebar.active")}>
          {active.map((chat) => (
            <li key={chat.id}>
              <button
                type="button"
                className="nt-all-row"
                data-state={chat.state}
                onClick={() => onOpenActive?.(chat.id)}
              >
                <span className="nt-all-glyph">
                  <AgentMark harness={chat.harness} />
                </span>
                <span className="nt-all-title">{chat.title}</span>
                <span className="nt-all-state">{chat.label}</span>
              </button>
            </li>
          ))}
        </ul>
      )}
      {state.loaded && rows.length === 0 ? (
        state.ready && <p className="nt-chats-empty">{state.query ? t("sidebar.noMatches") : nt("noChats")}</p>
      ) : (
        <ContextMenu className="nt-all-host" items={items} onOpen={() => setMenuTarget(menuKey.current)}>
          <div className="nt-all-scroll" onContextMenuCapture={() => (menuKey.current = undefined)}>
            <VirtualList
              className="nt-all-list"
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
