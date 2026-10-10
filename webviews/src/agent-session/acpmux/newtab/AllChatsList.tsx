// All chats on the New Tab page (Lawrence 2026-10-10, cx-n0i9; the sidebar has no All chats
// section any more): every coding agent chat on this computer, newest first, searchable. The
// list is virtualized (only the rows near the viewport are in the DOM) and paged: the host asks
// the daemon for one page at a time (`chats.page` -> `_acpmux/chats {query, limit, cursor}`), and
// the next page loads when its loader row scrolls into view. One click opens the chat in a new
// workspace with the agent pane (the host's Open Chat path); Open in terminal is in the row's
// right-click menu. The row look follows the TEMPORARY design picker (`sidebar.allChats.design`).
import React, { useCallback, useEffect, useRef, useState } from "react";
import { ContextMenu } from "../../../ui/ContextMenu";
import { VirtualList } from "../../../ui/VirtualList";
import { useT } from "../i18n";
import { AgentMark, ageLabel } from "../NewTabPage";
import { useNt } from "./strings";

export type AllChatsRow = { key: string; harness: string; title?: string; cwd?: string; updatedAt: number };
export type AllChatsDesign = "quiet" | "age" | "project";

export type AllChatsPage = {
  chats: AllChatsRow[];
  nextCursor?: string;
  ready?: boolean;
  enabled?: boolean;
  design?: string;
};

/// The host's `chats.page`; rejects or resolves undefined when the daemon cannot answer.
export type LoadChatsPage = (params: { query?: string; cursor?: string; limit: number }) => Promise<AllChatsPage | undefined>;

const PAGE = 100;
const ROW_HEIGHT = 32;

type State = {
  query: string;
  rows: AllChatsRow[];
  nextCursor?: string;
  loading: boolean;
  loaded: boolean;
  design: AllChatsDesign;
};

const initial: State = { query: "", rows: [], loading: false, loaded: false, design: "age" };

function design(value: unknown): AllChatsDesign | undefined {
  return value === "quiet" || value === "age" || value === "project" ? value : undefined;
}

function rowsOf(page: AllChatsPage | undefined): AllChatsRow[] {
  if (!page || !Array.isArray(page.chats)) return [];
  return page.chats.filter((row) => row && typeof row.key === "string" && typeof row.harness === "string");
}

/// The pages of one query: a new query starts over at the first page; a reply for an older query
/// or cursor is dropped (latest wins).
function useChatPages(load: LoadChatsPage) {
  const [state, setState] = useState<State>(initial);
  const generation = useRef(0);
  const inFlight = useRef<string | undefined>(undefined);
  const fetchPage = useCallback(
    (query: string, cursor: string | undefined) => {
      const ticket = cursor ? generation.current : ++generation.current;
      const marker = `${ticket}:${cursor ?? ""}`;
      if (inFlight.current === marker) return;
      inFlight.current = marker;
      setState((s) => (cursor ? { ...s, loading: true } : { ...s, query, loading: true }));
      void load({ ...(query ? { query } : {}), ...(cursor ? { cursor } : {}), limit: PAGE })
        .catch(() => undefined)
        .then((page) => {
          if (ticket !== generation.current) return;
          if (inFlight.current === marker) inFlight.current = undefined;
          setState((s) => {
            const fresh = rowsOf(page);
            const rows = cursor ? [...s.rows, ...fresh.filter((row) => !s.rows.some((old) => old.key === row.key))] : fresh;
            return {
              ...s,
              rows,
              ...(page?.nextCursor && fresh.length > 0 ? { nextCursor: page.nextCursor } : { nextCursor: undefined }),
              loading: false,
              loaded: true,
              design: design(page?.design) ?? s.design,
            };
          });
        });
    },
    [load],
  );
  // The first page when the list mounts (the page is a fresh view each time it shows).
  useEffect(() => {
    fetchPage("", undefined);
  }, [fetchPage]);
  return { state, fetchPage };
}

export function AllChatsList({
  load,
  onOpen,
  onOpenInTerminal,
  now = Date.now(),
}: {
  load: LoadChatsPage;
  onOpen(key: string): void;
  onOpenInTerminal?(key: string): void;
  now?: number;
}) {
  const t = useT();
  const nt = useNt();
  const { state, fetchPage } = useChatPages(load);
  const menuKey = useRef<string | undefined>(undefined);
  const { rows, nextCursor } = state;
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
    const project = row.cwd ? row.cwd.split("/").filter(Boolean).pop() : undefined;
    const meta = state.design === "age" ? ageLabel(row.updatedAt, now, t) : state.design === "project" ? project : undefined;
    return (
      <div
        key={row.key}
        role="listitem"
        className="nt-all-item"
        style={style}
        aria-posinset={index + 1}
        aria-setsize={count}
        onContextMenuCapture={() => (menuKey.current = row.key)}
      >
        <button type="button" className="nt-all-row" title={row.cwd ?? title} onClick={() => onOpen(row.key)}>
          {state.design === "quiet" && (
            <span className="nt-all-glyph">
              <AgentMark harness={row.harness} />
            </span>
          )}
          <span className="nt-all-title">{title}</span>
          {meta && <span className="nt-all-meta">{meta}</span>}
        </button>
      </div>
    );
  };
  const items = onOpenInTerminal
    ? [{ id: "terminal", label: t("shell.openInTerminal"), onSelect: () => menuKey.current && onOpenInTerminal(menuKey.current) }]
    : [];
  return (
    <section className="nt-all" aria-label={nt("allChats")}>
      <header className="nt-chats-head">
        <span className="nt-chats-tab is-selected">{nt("allChats")}</span>
        <input
          className="nt-all-search"
          type="search"
          value={state.query}
          placeholder={t("sidebar.searchPlaceholder")}
          aria-label={t("sidebar.search")}
          onChange={(event) => fetchPage(event.currentTarget.value, undefined)}
        />
      </header>
      {state.loaded && rows.length === 0 ? (
        <p className="nt-chats-empty">{state.query ? t("sidebar.noMatches") : nt("noChats")}</p>
      ) : (
        <ContextMenu items={items}>
          <VirtualList
            className="nt-all-list"
            role="list"
            label={nt("allChats")}
            count={count}
            estimateSize={() => ROW_HEIGHT}
            overscan={10}
            renderRow={renderRow}
          />
        </ContextMenu>
      )}
    </section>
  );
}
