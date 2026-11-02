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
import React, { useCallback, useEffect, useRef, useState } from "react";
import { devicePushCount, subscribeDeviceChats } from "./deviceChats";
import { chatsChangedSinceSettled, rememberChats, settledChats } from "./settledCache";
import { ContextMenu } from "../../../ui/ContextMenu";
import { pressToOpen } from "../../../ui/pressToOpen";
import { VirtualList } from "../../../ui/VirtualList";
import { useT } from "../i18n";
import { errorMessage } from "../transportErrors";
import { AgentMark, ageLabel } from "../NewTabPage";
import { useNt } from "./strings";
import { useMinuteClock } from "../clock";
import { ChatFilterMenu, type ChatStatusFilter } from "./ChatFilterMenu";
import { AllChatsLoading } from "./AllChatsLoading";

export type AllChatsRow = { key: string; harness: string; title?: string; cwd?: string; updatedAt: number };
export type AllChatsDesign = "quiet" | "age" | "project";
/// A chat that is running or waits on the user (acpmux's own sessions): it leads the list with
/// its state where the age would be.
export type ActiveChat = {
  id: string;
  title: string;
  harness?: string;
  state: "input" | "running" | "failed" | "error" | "unread" | "idle";
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

/// The header's Filter: All shows the list as it always was. Only live chats carry a state, so
/// Working and Needs input show live chats alone, and Done adds the indexed chats after them.
/// A failed or broken turn waits on the user as much as a question does.
const FILTER_STATES: Record<Exclude<ChatStatusFilter, "all">, ReadonlySet<ActiveChat["state"]>> = {
  working: new Set(["running"]),
  input: new Set(["input", "failed", "error"]),
  done: new Set(["unread", "idle"]),
};

const PAGE = 100;
const ROW_HEIGHT = 30;

type State = {
  query: string;
  rows: AllChatsRow[];
  nextCursor?: string;
  loading: boolean;
  loaded: boolean;
  /// The daemon's index has finished its first scan (`ready`); before that an empty page is not "No chats".
  ready: boolean;
  /// The last first-page read failed (the daemon did not answer): the list says so and offers Try again.
  failed: boolean;
  /// The cursor page that last failed. The loader stays in place, so it must expose its own retry.
  failedCursor?: string;
  /// The query `rows` answer; a failed read for another query drops them rather than show them under it.
  rowsQuery: string;
  design: AllChatsDesign;
};

const initial: State = {
  query: "",
  rows: [],
  loading: false,
  loaded: false,
  ready: false,
  failed: false,
  rowsQuery: "",
  design: "age",
};

/// The list a page starts with: the first page the last page read (settledCache.ts), drawn on the
/// first frame, else empty until its read lands.
function initialState(): State {
  const settled = settledChats();
  if (!settled) return initial;
  return {
    ...initial,
    rows: settled.rows,
    ...(settled.nextCursor ? { nextCursor: settled.nextCursor } : {}),
    loaded: true,
    ready: settled.ready,
    design: settled.design ?? initial.design,
  };
}

function design(value: unknown): AllChatsDesign | undefined {
  return value === "quiet" || value === "age" || value === "project" ? value : undefined;
}

function rowsOf(page: AllChatsPage | undefined): AllChatsRow[] {
  if (!page || !Array.isArray(page.chats)) return [];
  return page.chats.filter((row) => row && typeof row.key === "string" && typeof row.harness === "string");
}

/// A first page read again (a push from the chat index) over the loaded rows: its rows lead, and
/// the loaded rows it does not name keep their order below (they are older than all of it).
export function mergeFirstPage(fresh: AllChatsRow[], rows: AllChatsRow[]): AllChatsRow[] {
  const named = new Set(fresh.map((row) => row.key));
  return [...fresh, ...rows.filter((row) => !named.has(row.key))];
}

/// A project of the Projects view: the chats of one folder (`cwd` unset: chats in no project).
export type ChatProject = { key: string; cwd?: string; label?: string; rows: AllChatsRow[] };

/// The loaded chats by folder, each project where its newest chat stands (the rows come newest
/// first), its chats in their own order.
export function projectGroups(rows: AllChatsRow[]): ChatProject[] {
  const groups = new Map<string, ChatProject>();
  for (const row of rows) {
    const key = row.cwd ?? "";
    let group = groups.get(key);
    if (!group) {
      group = {
        key,
        rows: [],
        ...(row.cwd ? { cwd: row.cwd, label: row.cwd.split("/").filter(Boolean).pop() || row.cwd } : {}),
      };
      groups.set(key, group);
    }
    group.rows.push(row);
  }
  return [...groups.values()];
}

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

/// The pages of one query: a new query starts over at the first page (its old cursor is dropped
/// at once, so no page of the old query is asked for again); a reply for an older query is
/// dropped (latest wins). `load` may change identity on every parent render: the list keeps the
/// latest one in a ref, so a parent render never restarts the list.
export function useChatPages(load: LoadChatsPage) {
  const [state, setState] = useState<State>(initialState);
  // Rows from the settled first page: the mount reads only a change pushed since (see below).
  const [seeded] = useState(() => state.loaded);
  // A list drawn from a saved first page that mounts to a changed index takes that first read
  // whole: a chat deleted or archived since must not stay listed (merging keeps every row the
  // fresh page does not name). Pages read past the saved one meanwhile stay; only saved rows go.
  const replaceSaved = useRef(false);
  const [savedKeys] = useState(() => new Set(state.rows.map((row) => row.key)));
  const pagedPastSaved = useRef(false);
  const latestLoad = useRef(load);
  latestLoad.current = load;
  const generation = useRef(0);
  const inFlight = useRef<string | undefined>(undefined);
  const fetchPage = useCallback((query: string, cursor: string | undefined) => {
    const ticket = cursor ? generation.current : ++generation.current;
    const marker = `${ticket}:${cursor ?? ""}`;
    if (inFlight.current === marker) return;
    inFlight.current = marker;
    const atPush = devicePushCount();
    setState((s) =>
      cursor
        ? { ...s, loading: true, failedCursor: undefined }
        : { ...s, query, nextCursor: undefined, loading: true, failedCursor: undefined },
    );
    void latestLoad
      .current({ ...(query ? { query } : {}), ...(cursor ? { cursor } : {}), limit: PAGE })
      .catch(() => undefined)
      .then((page) => {
        if (ticket !== generation.current) return;
        if (inFlight.current === marker) inFlight.current = undefined;
        setState((s) => {
          // A failed page keeps the cursor. The loader may still be in view, so the row exposes Retry.
          if (!page)
            return {
              ...s,
              loading: false,
              loaded: true,
              ...(cursor
                ? { nextCursor: cursor, failedCursor: cursor }
                : { failed: true, rows: s.rowsQuery === query ? s.rows : [], nextCursor: undefined }),
            };
          const fresh = rowsOf(page);
          const nextCursor = page.nextCursor && fresh.length > 0 ? page.nextCursor : undefined;
          if (!cursor && !query)
            rememberChats(
              {
                rows: fresh,
                ready: page.ready !== false,
                ...(nextCursor ? { nextCursor } : {}),
                ...(design(page.design) ? { design: design(page.design) } : {}),
              },
              atPush,
            );
          if (cursor) pagedPastSaved.current = true;
          else replaceSaved.current = false;
          const known = new Set(s.rows.map((row) => row.key));
          const rows = cursor ? [...s.rows, ...fresh.filter((row) => !known.has(row.key))] : fresh;
          return {
            ...s,
            rows,
            nextCursor,
            loading: false,
            loaded: true,
            ready: page.ready !== false,
            failed: false,
            failedCursor: undefined,
            rowsQuery: query,
            design: design(page.design) ?? s.design,
          };
        });
      });
  }, []);
  // A loaded list reads its first page again when the index pushes a change and puts it on top of
  // its rows, keeping the later pages and the cursor (cx-heu). One read at a time: a push during
  // one reads once more after it. A query's list, or a new query meanwhile, is left alone.
  const refreshing = useRef<"idle" | "busy" | "again">("idle");
  const refreshFirstPage = useCallback(() => {
    if (refreshing.current !== "idle") {
      refreshing.current = "again";
      return;
    }
    refreshing.current = "busy";
    const ticket = generation.current;
    const atPush = devicePushCount();
    void latestLoad
      .current({ limit: PAGE })
      .catch(() => undefined)
      .then((page) => {
        if (page) {
          const fresh = rowsOf(page);
          const nextCursor = page.nextCursor && fresh.length > 0 ? page.nextCursor : undefined;
          rememberChats(
            {
              rows: fresh,
              ready: page.ready !== false,
              ...(nextCursor ? { nextCursor } : {}),
              ...(design(page.design) ? { design: design(page.design) } : {}),
            },
            atPush,
          );
        }
        if (page && ticket === generation.current) {
          const replace = replaceSaved.current;
          replaceSaved.current = false;
          setState((s) => {
            if (s.query) return s;
            const fresh = rowsOf(page);
            if (replace && !pagedPastSaved.current) {
              const nextCursor = page.nextCursor && fresh.length > 0 ? page.nextCursor : undefined;
              return { ...s, rows: fresh, nextCursor, ready: page.ready !== false };
            }
            // An index-ready first page without a cursor is the whole list: rows omitted from it
            // were deleted or archived. A paged first page cannot distinguish those from rows
            // that merely moved to a later page, so retain older fetched rows in that case.
            const complete = page.ready !== false && !page.nextCursor;
            const named = new Set(fresh.map((row) => row.key));
            const rows = complete
              ? fresh
              : mergeFirstPage(
                  fresh,
                  replace ? s.rows.filter((row) => !savedKeys.has(row.key) || named.has(row.key)) : s.rows,
                );
            // Most pushes change nothing on the first page: the list keeps its rows (no re-render).
            const same =
              rows.length === s.rows.length &&
              rows.every(
                (row, i) =>
                  row === s.rows[i] ||
                  (row.key === s.rows[i]?.key &&
                    row.updatedAt === s.rows[i]?.updatedAt &&
                    row.title === s.rows[i]?.title &&
                    row.cwd === s.rows[i]?.cwd),
              ) &&
              (!complete || (s.nextCursor === undefined && s.ready));
            return same ? s : { ...s, rows, ...(complete ? { nextCursor: undefined, ready: true } : {}) };
          });
        }
        const again = refreshing.current === "again";
        refreshing.current = "idle";
        if (again) refreshFirstPage();
      });
  }, [savedKeys]);
  // The first page when the list mounts. A list that drew the settled first page (a workspace
  // closed or opened and its page mounted again) reads it only for a change the chat index pushed
  // since; a later push reads it as on any loaded list (Leo 2026-10-18: the list emptied and refilled).
  useEffect(() => {
    if (!seeded) fetchPage("", undefined);
    else if (chatsChangedSinceSettled()) {
      replaceSaved.current = true;
      refreshFirstPage();
    }
  }, [seeded, fetchPage, refreshFirstPage]);
  // A page opened before the chat index finished its first scan (`ready: false`, or no rows yet)
  // reads its first page from the start when the host pushes the index's chats (cx-ztlw: the first
  // Cmd-T page stayed empty for good); a loaded one refreshes it. A search is left alone.
  const latest = useRef(state);
  latest.current = state;
  useEffect(
    () =>
      subscribeDeviceChats(() => {
        const current = latest.current;
        if (current.query) return;
        if (!current.ready || current.rows.length === 0) fetchPage("", undefined);
        else refreshFirstPage();
      }),
    [fetchPage, refreshFirstPage],
  );
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
  /// A plain open of `key`: the selection collapses and `key` anchors the next Shift-click.
  const collapse = (key: string) => {
    anchor.current = key;
    setSelected([]);
  };
  const clear = useCallback(() => setSelected([]), []);
  return { selected, click, collapse, clear };
}

/** A chat-open request keeps its originating row through host acceptance or refusal.
 * One click creates one request; a late refusal cannot overwrite a newer row's status.
 * A bulk History open reports failure without offering an unsafe all-rows replay.
 */
export function useChatOpenFeedback(
  onOpen: (key: string) => unknown,
  onBring?: (keys: string[]) => unknown,
) {
  const t = useT();
  const [opening, setOpening] = useState<string>();
  const [failure, setFailure] = useState<{ key?: string; message: string }>();
  const pending = useRef(new Set<string>());
  const newest = useRef(0);
  const message = (error: unknown) => errorMessage(error) || t("transport.refused");
  const open = (key: string) => {
    if (pending.current.has(key)) return;
    pending.current.add(key);
    const ticket = ++newest.current;
    setOpening(key);
    setFailure(undefined);
    // The call begins on this person gesture; the host requires that for some actions.
    let request: unknown;
    try {
      request = onOpen(key);
    } catch (error) {
      request = Promise.reject(error);
    }
    void Promise.resolve(request).then(
      () => {
        pending.current.delete(key);
        if (ticket === newest.current) setOpening(undefined);
      },
      (error: unknown) => {
        pending.current.delete(key);
        if (ticket !== newest.current) return;
        setOpening(undefined);
        setFailure({ key, message: message(error) });
      },
    );
  };
  const bring = (keys: string[]) => {
    if (!onBring) return;
    const ticket = ++newest.current;
    setOpening(undefined);
    setFailure(undefined);
    let request: unknown;
    try {
      request = onBring(keys);
    } catch (error) {
      request = Promise.reject(error);
    }
    // Some rows in a multi-open may have succeeded. Report the refusal without replaying them.
    void Promise.resolve(request).catch((error: unknown) => {
      if (ticket === newest.current) setFailure({ message: message(error) });
    });
  };
  return { opening, failure, open, bring };
}

/// A chat acpmux can show without running it: Claude Code and Codex (acpmux `hub/watch.rs`).
export const watchable = (key: string) => /^(claude-code|codex):./.test(key);

export function AllChatsList({
  load,
  onOpen,
  active = [],
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
  // The shared clock (clock.ts), as the New Tab cards: one age for one chat on every page.
  const clock = useMinuteClock();
  const now = fixedNow ?? clock;
  const { state, fetchPage } = useChatPages(load);
  const openFeedback = useChatOpenFeedback(onOpen, onBring);
  const menuKey = useRef<string | undefined>(undefined);
  const [menuTarget, setMenuTarget] = useState<string | undefined>(undefined);
  const { rows, nextCursor } = state;
  const [view, setView] = useState<"chats" | "projects">("chats");
  const [filter, setFilter] = useState<ChatStatusFilter>("all");
  // Working and Needs input are live chats only; the indexed rows are finished chats.
  const indexed = filter === "all" || filter === "done";
  const query = state.query.trim().toLowerCase();
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
  const [folded, setFolded] = useState<ReadonlySet<string>>(() => new Set());
  const entries = listEntries(rows, view, folded);
  // A Shift-click range runs over the chats as the list shows them.
  const shown = entries.flatMap((entry) => (entry.kind === "chat" ? [entry.row] : []));
  const selection = useSelection(shown, state.query);
  // The menu acts on the selection when the clicked row is in it, else on that row.
  const menuKeys = menuTarget ? (selection.selected.includes(menuTarget) ? selection.selected : [menuTarget]) : [];
  // While rows are selected, Enter opens them and Escape clears them. The page listens, not the
  // rows: WebKit does not focus a button on click, so after Cmd/Shift-click no row has focus.
  const { selected, clear } = selection;
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
      const label = project.label ?? nt("noProject");
      return (
        <div
          key={`project-${project.key}`}
          // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- a virtualized row (absolute, transformed), not a flow <li>
          role="listitem"
          className="nt-all-item"
          style={style}
          aria-posinset={index + 1}
          aria-setsize={count}
        >
          <button
            type="button"
            className="nt-all-group"
            data-focus-ring="row"
            aria-expanded={open}
            onClick={() => {
              // A folded chat cannot stay selected: Enter or Bring would act on rows out of sight.
              selection.clear();
              setFolded((current) => {
                const next = new Set(current);
                if (open) next.add(project.key);
                else next.delete(project.key);
                return next;
              });
            }}
          >
            <svg className="nt-all-group-chevron" viewBox="0 0 16 16" width="10" height="10" aria-hidden="true">
              <path d="m6 4 4 4-4 4" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
            </svg>
            <span className="nt-all-group-name">{label}</span>
            <span className="nt-all-group-count">{project.rows.length}</span>
          </button>
        </div>
      );
    }
    const row = entry.row;
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
          data-focus-ring="row"
          data-untitled={row.title ? undefined : true}
          data-selected={selection.selected.includes(row.key) ? true : undefined}
          aria-busy={openFeedback.opening === row.key}
          // A plain press opens at once; a Cmd/Shift-click selects on the release, and a press on a row
          // of a multi-selection waits for the release (the Finder rule).
          {...pressToOpen(
            () => {
              selection.collapse(row.key);
              openFeedback.open(row.key);
            },
            {
              deferPress: () => !!onBring && selection.selected.length > 1 && selection.selected.includes(row.key),
              onClick: (event) => {
                if (onBring && selection.click(event, row.key)) return;
                openFeedback.open(row.key);
              },
            },
          )}
        >
          <span className="nt-all-glyph">
            <AgentMark harness={row.harness} />
          </span>
          <span className="nt-all-title" title={title}>
            {title}
          </span>
          {project && state.design !== "quiet" && view === "chats" && (
            <span className="nt-all-project" title={row.cwd}>
              {project}
            </span>
          )}
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
      {activeShown.length > 0 && (
        <ul className="nt-all-active" aria-label={t("sidebar.active")}>
          {activeShown.map((chat) => (
            <li key={chat.id}>
              {/* Its right-click menu: Open, as its click (cx-2lm4). */}
              <ContextMenu
                className="nt-row-host"
                items={[{ id: "open", label: nt("row.open"), onSelect: () => onOpenActive?.(chat.id) }]}
              >
                <button
                  type="button"
                  className="nt-all-row"
                  data-focus-ring="row"
                  data-state={chat.state}
                  {...pressToOpen(() => onOpenActive?.(chat.id))}
                >
                  <span className="nt-all-glyph">
                    <AgentMark harness={chat.harness} />
                  </span>
                  <span className="nt-all-title" title={chat.title}>
                    {chat.title}
                  </span>
                  <span className="nt-all-state">{chat.label}</span>
                </button>
              </ContextMenu>
            </li>
          ))}
        </ul>
      )}
      {!indexed ? (
        activeShown.length === 0 && <p className="nt-chats-empty">{t("sidebar.noMatches")}</p>
      ) : rows.length === 0 && (!state.loaded || state.loading || (!state.ready && !state.failed)) ? (
        <AllChatsLoading rowHeight={ROW_HEIGHT} design={state.design} view={view} />
      ) : state.loaded && rows.length === 0 ? (
        state.failed ? (
          <output className="nt-chats-empty nt-chats-failed">
            {nt("chatsLoadFailed")}
            <button
              type="button"
              className="nt-chats-retry"
              disabled={state.loading}
              onClick={() => fetchPage(state.query, undefined)}
            >
              {t("picker.tryAgain")}
            </button>
          </output>
        ) : (
          state.ready && <p className="nt-chats-empty">{state.query ? t("sidebar.noMatches") : nt("noChats")}</p>
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
