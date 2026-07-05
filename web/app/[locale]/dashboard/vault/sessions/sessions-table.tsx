"use client";

import { useCallback, useMemo, useRef, useState } from "react";
import { useVirtualizer } from "@tanstack/react-virtual";
import { useLocale, useTranslations } from "next-intl";
import { Link, usePathname, useRouter } from "@/i18n/navigation";
import {
  VAULT_SESSION_LIST_PAGE_SIZE,
  type SerializedVaultSessionListPage,
  type SerializedVaultSessionListRow,
} from "@/services/vault/sessionList";
import {
  formatBytes,
  formatDate,
  formatRelativeTime,
  pathBasename,
  truncateMiddle,
} from "@/services/vault/format";

type SessionsTableProps = {
  readonly initialQuery: string;
  readonly initialRows: readonly SerializedVaultSessionListRow[];
  readonly initialNextCursor: string | null;
};

const LOAD_MORE_THRESHOLD = 20;

export function SessionsTable({
  initialQuery,
  initialRows,
  initialNextCursor,
}: SessionsTableProps) {
  const t = useTranslations("vault.sessions");
  const locale = useLocale();
  const router = useRouter();
  const pathname = usePathname();
  const [rows, setRows] = useState<readonly SerializedVaultSessionListRow[]>(initialRows);
  const [nextCursor, setNextCursor] = useState<string | null>(initialNextCursor);
  const [query, setQuery] = useState(initialQuery);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState(false);
  const [scrollElement, setScrollElement] = useState<HTMLDivElement | null>(null);
  const loadingRef = useRef(false);
  const requestIdRef = useRef(0);
  const searchTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const activeQueryRef = useRef(initialQuery);

  const clearSearchTimer = useCallback(() => {
    if (!searchTimerRef.current) return;
    clearTimeout(searchTimerRef.current);
    searchTimerRef.current = null;
  }, []);

  const rowVirtualizer = useVirtualizer({
    count: rows.length + 1,
    getScrollElement: () => scrollElement,
    estimateSize: () => 72,
    overscan: 12,
  });

  const virtualItems = rowVirtualizer.getVirtualItems();
  const now = useMemo(() => new Date(), [rows]);

  const replaceUrl = useCallback(
    (nextQuery: string) => {
      const params = new URLSearchParams();
      if (nextQuery.trim()) params.set("q", nextQuery.trim());
      const qs = params.toString();
      router.replace(`${pathname}${qs ? `?${qs}` : ""}`);
    },
    [pathname, router],
  );

  const fetchPage = useCallback(
    async ({
      reset,
      nextQuery,
    }: {
      readonly reset: boolean;
      readonly nextQuery: string;
    }) => {
      if (loadingRef.current && !reset) return;
      if (loadingRef.current && reset) {
        requestIdRef.current += 1;
        loadingRef.current = false;
      }
      const cursor = reset ? null : nextCursor;
      if (!reset && !cursor) return;

      const requestId = ++requestIdRef.current;
      loadingRef.current = true;
      setLoading(true);
      setError(false);

      const params = new URLSearchParams({
        limit: String(VAULT_SESSION_LIST_PAGE_SIZE),
      });
      if (nextQuery.trim()) params.set("q", nextQuery.trim());
      if (cursor) params.set("cursor", cursor);

      try {
        const response = await fetch(`/api/vault/sessions?${params}`, {
          credentials: "same-origin",
        });
        if (!response.ok) throw new Error("sessions_fetch_failed");
        const data = (await response.json()) as SerializedVaultSessionListPage;
        if (requestId !== requestIdRef.current) return;
        setRows((current) => {
          if (reset) return data.sessions;
          const seen = new Set(current.map((row) => row.id));
          return [...current, ...data.sessions.filter((row) => !seen.has(row.id))];
        });
        setNextCursor(data.nextCursor ?? null);
      } catch {
        if (requestId === requestIdRef.current) setError(true);
      } finally {
        if (requestId === requestIdRef.current) {
          loadingRef.current = false;
          setLoading(false);
        }
      }
    },
    [nextCursor],
  );

  const applyFilters = useCallback(
    (nextQuery: string) => {
      clearSearchTimer();
      activeQueryRef.current = nextQuery;
      setQuery(nextQuery);
      setRows([]);
      setNextCursor(null);
      replaceUrl(nextQuery);
      void fetchPage({ reset: true, nextQuery });
      scrollElement?.scrollTo({ top: 0 });
    },
    [clearSearchTimer, fetchPage, replaceUrl, scrollElement],
  );

  const onSearchChange = useCallback(
    (value: string) => {
      setQuery(value);
      clearSearchTimer();
      searchTimerRef.current = setTimeout(() => {
        applyFilters(value);
      }, 250);
    },
    [applyFilters, clearSearchTimer],
  );

  const maybeLoadMore = useCallback(() => {
    const last = rowVirtualizer.getVirtualItems().at(-1);
    if (!last || last.index < rows.length - LOAD_MORE_THRESHOLD) return;
    void fetchPage({
      reset: false,
      nextQuery: activeQueryRef.current,
    });
  }, [fetchPage, rowVirtualizer, rows.length]);

  const status = loading
    ? t("loadingMore")
    : error
      ? t("loadError")
      : nextCursor
        ? t("scrollForMore")
        : rows.length === 0
          ? t("noResults")
          : t("endOfList");

  return (
    <div className="flex h-[calc(100vh-2.75rem)] min-h-[520px] flex-col px-3 py-3">
      <div className="mb-3 flex flex-col gap-2 border-b border-border pb-3 lg:flex-row lg:items-end lg:justify-between">
        <div>
          <p className="text-xs font-medium text-muted">{t("eyebrow")}</p>
          <h1 className="mt-1 text-sm font-medium">{t("title")}</h1>
          <p className="mt-1 max-w-2xl text-muted">{t("description")}</p>
        </div>
        <Link
          href="/dashboard/vault"
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
            onChange={(event) => onSearchChange(event.target.value)}
            placeholder={t("searchPlaceholder")}
            className="w-full border border-border bg-background px-3 py-1.5 text-foreground focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground"
          />
        </label>
      </div>

      <div className="overflow-hidden border border-border">
        <div
          role="row"
          className="grid min-w-[1040px] grid-cols-[92px_180px_minmax(260px,1fr)_112px_132px_112px_152px_152px] border-b border-border px-3 py-2 text-xs font-medium text-muted"
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
          ref={setScrollElement}
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
              const row = rows[virtualRow.index];
              if (!row) {
                return (
                  <div
                    key="status"
                    role="row"
                    className="absolute left-0 top-0 flex w-full items-center px-3 text-muted"
                    style={{
                      height: `${virtualRow.size}px`,
                      transform: `translateY(${virtualRow.start}px)`,
                    }}
                  >
                    {status}
                  </div>
                );
              }
              return (
                <SessionRow
                  key={row.id}
                  row={row}
                  locale={locale}
                  now={now}
                  copyLabel={t("copySession")}
                  copiedLabel={t("copiedSession")}
                  unknownCwd={t("unknownCwd")}
                  onNavigate={clearSearchTimer}
                  style={{
                    height: `${virtualRow.size}px`,
                    transform: `translateY(${virtualRow.start}px)`,
                  }}
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
  copyLabel,
  copiedLabel,
  unknownCwd,
  onNavigate,
  style,
}: {
  readonly row: SerializedVaultSessionListRow;
  readonly locale: string;
  readonly now: Date;
  readonly copyLabel: string;
  readonly copiedLabel: string;
  readonly unknownCwd: string;
  readonly onNavigate: () => void;
  readonly style: React.CSSProperties;
}) {
  const router = useRouter();
  const [copied, setCopied] = useState(false);
  const cwd = row.cwd || unknownCwd;
  const basename = pathBasename(row.cwd) || unknownCwd;
  const openSession = () => {
    onNavigate();
    router.push(`/dashboard/vault/sessions/${row.id}`);
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
      className="group absolute left-0 top-0 grid w-full cursor-pointer grid-cols-[92px_180px_minmax(260px,1fr)_112px_132px_112px_152px_152px] items-center border-b border-border px-3 text-xs focus-visible:outline focus-visible:-outline-offset-1 focus-visible:outline-1 focus-visible:outline-foreground hover:bg-foreground hover:text-background"
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
          aria-label={copied ? copiedLabel : copyLabel}
          title={copied ? copiedLabel : copyLabel}
        >
          {copied ? copiedLabel : copyLabel}
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
