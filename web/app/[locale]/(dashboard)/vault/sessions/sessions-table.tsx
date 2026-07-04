"use client";

import { useCallback, useMemo, useRef, useState } from "react";
import { useVirtualizer } from "@tanstack/react-virtual";
import { useLocale, useTranslations } from "next-intl";
import { Link, usePathname, useRouter } from "@/i18n/navigation";
import {
  VAULT_SESSION_LIST_PAGE_SIZE,
  type SerializedVaultSessionListPage,
  type SerializedVaultSessionListRow,
  type VaultSessionListAgent,
} from "@/services/vault/sessionList";
import {
  formatBytes,
  formatDate,
  formatRelativeTime,
  pathBasename,
  truncateMiddle,
} from "@/services/vault/format";

type SessionsTableProps = {
  readonly initialAgent: VaultSessionListAgent;
  readonly initialQuery: string;
  readonly initialRows: readonly SerializedVaultSessionListRow[];
  readonly initialNextCursor: string | null;
};

const AGENTS: readonly VaultSessionListAgent[] = ["all", "claude", "codex", "pi"];
const LOAD_MORE_THRESHOLD = 20;

export function SessionsTable({
  initialAgent,
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
  const [agent, setAgent] = useState<VaultSessionListAgent>(initialAgent);
  const [query, setQuery] = useState(initialQuery);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState(false);
  const [scrollElement, setScrollElement] = useState<HTMLDivElement | null>(null);
  const loadingRef = useRef(false);
  const requestIdRef = useRef(0);
  const searchTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const activeFilterRef = useRef({ agent: initialAgent, query: initialQuery });

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
    (nextAgent: VaultSessionListAgent, nextQuery: string) => {
      const params = new URLSearchParams();
      if (nextAgent !== "all") params.set("agent", nextAgent);
      if (nextQuery.trim()) params.set("q", nextQuery.trim());
      const qs = params.toString();
      router.replace(`${pathname}${qs ? `?${qs}` : ""}`);
    },
    [pathname, router],
  );

  const fetchPage = useCallback(
    async ({
      reset,
      nextAgent,
      nextQuery,
    }: {
      readonly reset: boolean;
      readonly nextAgent: VaultSessionListAgent;
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
      if (nextAgent !== "all") params.set("agent", nextAgent);
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
    (nextAgent: VaultSessionListAgent, nextQuery: string) => {
      clearSearchTimer();
      activeFilterRef.current = { agent: nextAgent, query: nextQuery };
      setAgent(nextAgent);
      setQuery(nextQuery);
      setRows([]);
      setNextCursor(null);
      replaceUrl(nextAgent, nextQuery);
      void fetchPage({ reset: true, nextAgent, nextQuery });
      scrollElement?.scrollTo({ top: 0 });
    },
    [clearSearchTimer, fetchPage, replaceUrl, scrollElement],
  );

  const onSearchChange = useCallback(
    (value: string) => {
      setQuery(value);
      clearSearchTimer();
      searchTimerRef.current = setTimeout(() => {
        applyFilters(activeFilterRef.current.agent, value);
      }, 250);
    },
    [applyFilters, clearSearchTimer],
  );

  const maybeLoadMore = useCallback(() => {
    const last = rowVirtualizer.getVirtualItems().at(-1);
    if (!last || last.index < rows.length - LOAD_MORE_THRESHOLD) return;
    void fetchPage({
      reset: false,
      nextAgent: activeFilterRef.current.agent,
      nextQuery: activeFilterRef.current.query,
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
    <div className="flex h-[calc(100vh-3.5rem)] min-h-[640px] flex-col px-4 py-6 sm:px-6">
      <div className="mb-5 flex flex-col gap-4 lg:flex-row lg:items-end lg:justify-between">
        <div>
          <p className="text-sm font-medium text-muted">{t("eyebrow")}</p>
          <h1 className="mt-2 text-3xl font-semibold">{t("title")}</h1>
          <p className="mt-3 max-w-2xl text-sm leading-6 text-muted">{t("description")}</p>
        </div>
        <Link
          href="/vault"
          className="text-sm text-muted underline underline-offset-4 hover:text-foreground"
        >
          {t("backToOverview")}
        </Link>
      </div>

      <div className="mb-4 flex flex-col gap-3 lg:flex-row lg:items-center lg:justify-between">
        <div className="flex gap-2 overflow-x-auto">
          {AGENTS.map((item) => (
            <button
              key={item}
              type="button"
              onClick={() => applyFilters(item, query)}
              className={`rounded-md border px-3 py-2 text-sm transition-colors ${
                agent === item
                  ? "border-foreground bg-foreground text-background"
                  : "border-border text-muted hover:text-foreground"
              }`}
            >
              {item === "all" ? t("agents.all") : t(`agents.${item}`)}
            </button>
          ))}
        </div>
        <label className="min-w-0 lg:w-80">
          <span className="sr-only">{t("searchLabel")}</span>
          <input
            value={query}
            onChange={(event) => onSearchChange(event.target.value)}
            placeholder={t("searchPlaceholder")}
            className="h-10 w-full rounded-md border border-border bg-background px-3 text-sm outline-none focus:border-foreground"
          />
        </label>
      </div>

      <div className="overflow-hidden rounded-md border border-border">
        <div
          role="row"
          className="grid min-w-[1040px] grid-cols-[92px_180px_minmax(260px,1fr)_112px_132px_112px_152px_152px] border-b border-border bg-muted/5 px-4 py-3 text-xs font-medium uppercase text-muted"
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
                    className="absolute left-0 top-0 flex w-full items-center px-4 text-sm text-muted"
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

  return (
    <div
      role="row"
      onClick={() => {
        onNavigate();
        router.push(`/vault/sessions/${row.id}`);
      }}
      className="absolute left-0 top-0 grid w-full cursor-pointer grid-cols-[92px_180px_minmax(260px,1fr)_112px_132px_112px_152px_152px] items-center border-b border-border px-4 text-sm transition-colors hover:bg-muted/5"
      style={style}
    >
      <div role="cell">
        <span className={`rounded-full px-2 py-1 text-xs font-medium ${agentBadgeClass(row.agent)}`}>
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
          className="rounded border border-border px-1.5 py-0.5 text-xs text-muted hover:text-foreground"
          aria-label={copied ? copiedLabel : copyLabel}
          title={copied ? copiedLabel : copyLabel}
        >
          {copied ? copiedLabel : copyLabel}
        </button>
      </div>
      <div role="cell" className="min-w-0 pr-5">
        <div className="truncate font-medium" title={cwd}>
          {basename}
        </div>
        <div className="truncate text-xs text-muted" title={cwd}>
          {truncateMiddle(cwd, 72)}
        </div>
      </div>
      <div role="cell" className="tabular-nums">
        {formatBytes(row.sizeBytes, locale)}
      </div>
      <div role="cell" className="tabular-nums">
        {formatBytes(row.compressedSizeBytes, locale)}
      </div>
      <div role="cell" className="tabular-nums">
        {row.snapshotCount.toLocaleString(locale)}
      </div>
      <div role="cell" className="text-muted" title={formatDate(row.firstUploadedAt, locale)}>
        {formatDate(row.firstUploadedAt, locale)}
      </div>
      <div role="cell" className="text-muted" title={formatDate(row.lastUploadedAt, locale)}>
        {formatRelativeTime(row.lastUploadedAt, locale, now)}
      </div>
    </div>
  );
}

function agentBadgeClass(agent: string): string {
  if (agent === "claude") return "bg-orange-500/10 text-orange-700 dark:text-orange-300";
  if (agent === "codex") return "bg-emerald-500/10 text-emerald-700 dark:text-emerald-300";
  if (agent === "pi") return "bg-sky-500/10 text-sky-700 dark:text-sky-300";
  return "bg-muted/10 text-muted";
}
