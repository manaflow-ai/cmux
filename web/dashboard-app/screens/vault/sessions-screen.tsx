"use client";

import { useInfiniteQuery } from "@tanstack/react-query";
import { Link, useNavigate } from "@tanstack/react-router";
import { useVirtualizer } from "@tanstack/react-virtual";
import { useLocale, useTranslations } from "next-intl";
import { useCallback, useMemo, useRef, useState, useSyncExternalStore } from "react";
import type { SerializedVaultSessionListRow } from "@/services/vault/sessionList";
import {
  formatBytes,
  formatDate,
  formatRelativeTime,
  pathBasename,
  truncateMiddle,
} from "@/services/vault/format";
import { vaultSessionsQuery } from "../../queries/vault";
import { vaultSessionsRoute } from "../../routes/vault";

const LOAD_MORE_THRESHOLD = 20;
const RELATIVE_TIME_REFRESH_MS = 30_000;
const SEARCH_DEBOUNCE_MS = 250;
const ROW_GRID =
  "grid-cols-[92px_180px_minmax(260px,1fr)_112px_132px_112px_152px_152px]";

type Translator = ReturnType<typeof useTranslations<"vault.sessions">>;

/**
 * `/dashboard/vault/sessions`. The URL holds the applied filter; the input
 * holds what the user is typing. The list uses a non-suspending query so a
 * new filter clears the rows in place instead of unmounting the search box.
 */
export function VaultSessionsScreen() {
  const search = vaultSessionsRoute.useSearch();
  const navigate = useNavigate({ from: vaultSessionsRoute.fullPath });
  const appliedQuery = search.q?.trim() ?? "";
  const list = useInfiniteQuery(vaultSessionsQuery({
    q: appliedQuery,
    cursor: search.cursor ?? search.before ?? null,
  }));
  const [query, setQuery] = useState(appliedQuery);
  const searchTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const [scrollElement, setScrollElement] = useState<HTMLDivElement | null>(null);

  const clearSearchTimer = useCallback(() => {
    if (!searchTimerRef.current) return;
    clearTimeout(searchTimerRef.current);
    searchTimerRef.current = null;
  }, []);

  const applyQuery = useCallback((value: string) => {
    clearSearchTimer();
    const trimmed = value.trim();
    void navigate({
      search: (previous) => ({ team: previous.team, q: trimmed || undefined }),
      replace: true,
    });
    scrollElement?.scrollTo({ top: 0 });
  }, [clearSearchTimer, navigate, scrollElement]);

  const onSearchChange = useCallback((value: string) => {
    setQuery(value);
    clearSearchTimer();
    searchTimerRef.current = setTimeout(() => applyQuery(value), SEARCH_DEBOUNCE_MS);
  }, [applyQuery, clearSearchTimer]);

  const rows = useMemo(() => dedupeRows(list.data?.pages ?? []), [list.data]);
  const status = listStatus(list, rows.length);
  const now = useRelativeNow(list.dataUpdatedAt);
  const { fetchNextPage, hasNextPage, isFetchingNextPage } = list;
  const loadMore = useCallback(() => {
    if (hasNextPage && !isFetchingNextPage) void fetchNextPage();
  }, [fetchNextPage, hasNextPage, isFetchingNextPage]);

  return (
    <SessionsTableView
      query={query}
      onQueryChange={onSearchChange}
      rows={rows}
      status={status}
      now={now}
      scrollRef={setScrollElement}
      scrollElement={scrollElement}
      onNearEnd={loadMore}
      onNavigate={clearSearchTimer}
    />
  );
}

export type SessionsListStatus = "loading" | "error" | "more" | "empty" | "end";

function listStatus(
  list: { isPending: boolean; isFetchingNextPage: boolean; isError: boolean; hasNextPage: boolean },
  rowCount: number,
): SessionsListStatus {
  if (list.isPending || list.isFetchingNextPage) return "loading";
  if (list.isError) return "error";
  if (list.hasNextPage) return "more";
  return rowCount === 0 ? "empty" : "end";
}

function dedupeRows(
  pages: readonly { readonly sessions: readonly SerializedVaultSessionListRow[] }[],
): readonly SerializedVaultSessionListRow[] {
  const seen = new Set<string>();
  const rows: SerializedVaultSessionListRow[] = [];
  for (const page of pages) {
    for (const row of page.sessions) {
      if (seen.has(row.id)) continue;
      seen.add(row.id);
      rows.push(row);
    }
  }
  return rows;
}

function subscribeRelativeClock(onTick: () => void) {
  const timer = window.setInterval(onTick, RELATIVE_TIME_REFRESH_MS);
  return () => window.clearInterval(timer);
}

function relativeClockTick() {
  return Math.floor(Date.now() / RELATIVE_TIME_REFRESH_MS);
}

/**
 * "Now" for relative upload times: advances every 30 seconds and whenever a
 * page of rows arrives, so fresh rows never read as in the future.
 */
function useRelativeNow(dataUpdatedAt: number): Date {
  const tick = useSyncExternalStore(subscribeRelativeClock, relativeClockTick, relativeClockTick);
  return useMemo(
    () => new Date(Math.max(tick * RELATIVE_TIME_REFRESH_MS, dataUpdatedAt)),
    [tick, dataUpdatedAt],
  );
}

function statusLabel(status: SessionsListStatus, t: Translator): string {
  switch (status) {
    case "loading": return t("loadingMore");
    case "error": return t("loadError");
    case "more": return t("scrollForMore");
    case "empty": return t("noResults");
    case "end": return t("endOfList");
  }
}

export function SessionsTableView({
  query,
  onQueryChange,
  rows,
  status,
  now,
  scrollRef,
  scrollElement,
  onNearEnd,
  onNavigate,
}: {
  readonly query: string;
  readonly onQueryChange: (value: string) => void;
  readonly rows: readonly SerializedVaultSessionListRow[];
  readonly status: SessionsListStatus;
  readonly now: Date;
  readonly scrollRef: (node: HTMLDivElement | null) => void;
  readonly scrollElement: HTMLDivElement | null;
  readonly onNearEnd: () => void;
  readonly onNavigate: () => void;
}) {
  const t = useTranslations("vault.sessions");
  const locale = useLocale();
  const rowVirtualizer = useVirtualizer({
    count: rows.length + 1,
    getScrollElement: () => scrollElement,
    estimateSize: () => 72,
    overscan: 12,
  });
  const virtualItems = rowVirtualizer.getVirtualItems();
  const maybeLoadMore = () => {
    const last = rowVirtualizer.getVirtualItems().at(-1);
    if (last && last.index >= rows.length - LOAD_MORE_THRESHOLD) onNearEnd();
  };

  return (
    <div className="flex h-[calc(100vh-2.75rem)] min-h-[520px] flex-col px-3 py-3">
      <div className="mb-3 flex flex-col gap-2 border-b border-border pb-3 lg:flex-row lg:items-end lg:justify-between">
        <div>
          <p className="text-xs font-medium text-muted">{t("eyebrow")}</p>
          <h1 className="mt-1 text-sm font-medium">{t("title")}</h1>
          <p className="mt-1 max-w-2xl text-muted">{t("description")}</p>
        </div>
        <Link
          to="/dashboard/vault"
          className="text-muted focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground hover:underline"
        >
          {t("backToOverview")}
        </Link>
      </div>

      <div className="mb-3 flex justify-end">
        <label className="min-w-0 lg:w-80">
          <span className="sr-only">{t("searchLabel")}</span>
          <input
            value={query}
            onChange={(event) => onQueryChange(event.target.value)}
            placeholder={t("searchPlaceholder")}
            className="w-full border border-border bg-background px-3 py-1.5 text-foreground focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground"
          />
        </label>
      </div>

      <div className="overflow-hidden border border-border">
        <div
          role="row"
          className={`grid min-w-[1040px] ${ROW_GRID} border-b border-border px-3 py-2 text-xs font-medium text-muted`}
        >
          <div role="columnheader">{t("agent")}</div>
          <div role="columnheader">{t("session")}</div>
          <div role="columnheader">{t("cwd")}</div>
          <div role="columnheader">{t("rawSize")}</div>
          <div role="columnheader">{t("compressedSize")}</div>
          <div role="columnheader">{t("snapshots")}</div>
          <div role="columnheader">{t("firstUploaded")}</div>
          <div role="columnheader">{t("lastUploaded")}</div>
        </div>
        <div
          ref={scrollRef}
          onScroll={maybeLoadMore}
          role="table"
          aria-label={t("tableLabel")}
          className="h-[calc(100vh-20rem)] min-h-[360px] overflow-auto"
        >
          <div
            className="relative min-w-[1040px]"
            style={{ height: `${rowVirtualizer.getTotalSize()}px` }}
          >
            {virtualItems.map((virtualRow) => {
              const style = {
                height: `${virtualRow.size}px`,
                transform: `translateY(${virtualRow.start}px)`,
              };
              const row = rows[virtualRow.index];
              if (!row) {
                return (
                  <div
                    key="status"
                    role="row"
                    className="absolute left-0 top-0 flex w-full items-center px-3 text-muted"
                    style={style}
                  >
                    {statusLabel(status, t)}
                  </div>
                );
              }
              return (
                <SessionRow
                  key={row.id}
                  row={row}
                  locale={locale}
                  now={now}
                  t={t}
                  onNavigate={onNavigate}
                  style={style}
                />
              );
            })}
          </div>
        </div>
      </div>
    </div>
  );
}

function SessionRow({
  row,
  locale,
  now,
  t,
  onNavigate,
  style,
}: {
  readonly row: SerializedVaultSessionListRow;
  readonly locale: string;
  readonly now: Date;
  readonly t: Translator;
  readonly onNavigate: () => void;
  readonly style: React.CSSProperties;
}) {
  const navigate = useNavigate();
  const [copied, setCopied] = useState(false);
  const unknownCwd = t("unknownCwd");
  const cwd = row.cwd || unknownCwd;
  const basename = pathBasename(row.cwd) || unknownCwd;
  const copyLabel = copied ? t("copiedSession") : t("copySession");
  const openSession = () => {
    onNavigate();
    void navigate({ to: "/dashboard/vault/sessions/$id", params: { id: row.id } });
  };

  return (
    <div
      role="row"
      // The row cannot be an anchor because it contains a nested copy button,
      // so give it explicit keyboard semantics instead.
      tabIndex={0}
      onClick={openSession}
      onKeyDown={(event) => {
        if (event.target !== event.currentTarget) return;
        if (event.key !== "Enter" && event.key !== " ") return;
        event.preventDefault();
        openSession();
      }}
      className={`group absolute left-0 top-0 grid w-full cursor-pointer ${ROW_GRID} items-center border-b border-border px-3 text-xs focus-visible:outline focus-visible:-outline-offset-1 focus-visible:outline-1 focus-visible:outline-foreground hover:bg-foreground hover:text-background`}
      style={style}
    >
      <div role="cell">
        <span className="border border-border px-2 py-1 font-mono text-xs font-medium">
          {row.agent}
        </span>
      </div>
      <div role="cell" className="flex min-w-0 items-center gap-2">
        <span className="truncate font-mono text-xs" title={row.agentSessionId}>
          {truncateMiddle(row.agentSessionId, 18)}
        </span>
        <button
          type="button"
          onClick={(event) => {
            event.stopPropagation();
            void navigator.clipboard.writeText(row.agentSessionId);
            setCopied(true);
          }}
          className="border border-border bg-background px-2 py-1 text-xs text-foreground focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground hover:bg-foreground hover:text-background"
          aria-label={copyLabel}
          title={copyLabel}
        >
          {copyLabel}
        </button>
      </div>
      <div role="cell" className="min-w-0 pr-5">
        <div className="truncate font-mono text-xs" title={cwd}>
          {basename}
        </div>
        <div className="truncate font-mono text-xs text-muted group-hover:text-background" title={cwd}>
          {truncateMiddle(cwd, 72)}
        </div>
      </div>
      <div role="cell" className="font-mono text-xs tabular-nums">
        {formatBytes(row.sizeBytes, locale)}
      </div>
      <div role="cell" className="font-mono text-xs tabular-nums">
        {formatBytes(row.compressedSizeBytes, locale)}
      </div>
      <div role="cell" className="font-mono text-xs tabular-nums">
        {row.snapshotCount.toLocaleString(locale)}
      </div>
      <div
        role="cell"
        className="font-mono text-xs text-muted group-hover:text-background"
        title={formatDate(row.firstUploadedAt, locale)}
      >
        {formatDate(row.firstUploadedAt, locale)}
      </div>
      <div
        role="cell"
        className="font-mono text-xs text-muted group-hover:text-background"
        title={formatDate(row.lastUploadedAt, locale)}
      >
        {formatRelativeTime(row.lastUploadedAt, locale, now)}
      </div>
    </div>
  );
}
