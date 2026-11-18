// The GitHub page's CI dashboard (Leo, 2026-11-07: "we can use this as a way to follow up and just
// keep track of CI as it runs ... here's your big dashboard"): the tally and the share done with an
// ETA on top; failing jobs first with the step that failed and the end of its log; running jobs
// with how long they have run; queued; then every passed job folded into one line. A matrix's
// shards are one row with a pip per shard. Re-run failed reruns the failed jobs through gh's
// normal path on a click.
//
// A head can have thousands of jobs (GitHubChecks.swift reads up to 40 suites of 100 runs), so a
// long dashboard mounts only the lines near the viewport (useDashboardWindow, over the page's own
// scroll), each row is a memoized CiRow that draws again only when its own jobs change, and the
// clock's tick redraws only the rows with a running job.
import {
  defaultRangeExtractor,
  measureElement,
  useWindowVirtualizer,
  type Range,
  type Virtualizer,
} from "@tanstack/react-virtual";
import {
  memo,
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type FocusEvent,
  type RefObject,
} from "react";
import type { Strings } from "../shared/i18n";
import {
  dashboardBuckets,
  dashboardEta,
  dashboardItems,
  dashboardRows,
  dashboardTally,
  duration,
  elapsed,
  failedRuns,
  itemSize,
  keepRows,
  liveRow,
  timedJobs,
  type DashboardItem,
  type DashboardRow,
  type DashboardSize,
} from "./checksModel";
import type { GitHubStore } from "./store";
import type { DashboardChecks, DashboardJob, RerunState } from "./types";

/** Past this many items (titles and lines) the dashboard mounts only those near the viewport. */
export const WINDOW_ITEMS = 40;
/** About a viewport of lines (24 px each) above and below the visible ones. */
const OVERSCAN = 30;
/** Heights before the first item of a kind is measured (styles.css: a 24 px line, a 32 px title with its gap). */
const ESTIMATES: Record<DashboardSize, number> = {
  title: 24,
  "title-gap": 32,
  fold: 24,
  "fold-gap": 32,
  line: 24,
  failure: 120,
};

/** The clock as the dashboard reads it: read again once a second while a job runs and the page is
 *  shown, for its elapsed time; stops when none runs. Read on a tick, not on every render, so a scroll
 *  step or an answer that changes one job draws again no running row whose time did not move. */
function useClock(now: () => number, running: boolean): number {
  const [at, setAt] = useState(now);
  useEffect(() => {
    if (!running) return;
    setAt(now());
    const timer = setInterval(() => {
      if (document.visibilityState === "visible") setAt(now());
    }, 1000);
    return () => clearInterval(timer);
  }, [now, running]);
  return at;
}

const GROUP_TITLES = {
  failed: "github.checks.failing",
  running: "github.checks.running",
  queued: "github.checks.queued",
} as const;

export function ChecksDashboard({
  checks,
  rerun,
  store,
  strings,
  now,
  open,
}: {
  checks: DashboardChecks;
  rerun: RerunState;
  store: GitHubStore;
  strings: Strings;
  now: () => number;
  open: (url: string) => void;
}) {
  const { t } = strings;
  const [showPassed, setShowPassed] = useState(false);
  // Once per answer, never per tick: the rows (each kept as it was when its jobs say the same), the
  // tally, the jobs the ETA reads and the runs Re-run failed reruns.
  const held = useRef<DashboardRow[]>([]);
  const rows = useMemo(() => (held.current = keepRows(held.current, dashboardRows(checks.jobs))), [checks.jobs]);
  const buckets = useMemo(() => dashboardBuckets(rows), [rows]);
  const tallied = useMemo(() => dashboardTally(checks.jobs), [checks.jobs]);
  const timed = useMemo(() => timedJobs(checks.jobs), [checks.jobs]);
  const runs = useMemo(() => failedRuns(checks.jobs), [checks.jobs]);
  const at = useClock(now, tallied.running > 0);
  const summary = { ...tallied, eta: dashboardEta(timed, at) };
  const list = useRef<HTMLDivElement | null>(null);
  const columns = useColumns(list, summary.total > 0);
  const items = useMemo(() => dashboardItems(buckets, showPassed, columns), [buckets, showPassed, columns]);
  const shown = useDashboardWindow(list, items);
  const togglePassed = useCallback(() => setShowPassed((on) => !on), []);
  const tally: [string, number, string][] = [
    ["failed", summary.failed, "github.checks.failing"],
    ["running", summary.running, "github.checks.running"],
    ["queued", summary.queued, "github.checks.queued"],
    ["passed", summary.passed, "github.checks.passed"],
  ];
  return (
    <section className="gh-section gh-ci">
      <h2 className="gh-section-title">
        <span>{t("github.checks")}</span>
        {runs.length > 0 && (
          <button
            type="button"
            className="gh-button gh-ci-rerun"
            disabled={rerun.phase === "running"}
            onClick={() => void store.rerunFailed()}
          >
            {t(rerun.phase === "running" ? "github.checks.rerunning" : "github.checks.rerun")}
          </button>
        )}
      </h2>
      {rerun.phase === "failed" && rerun.message && (
        <p className="gh-failure gh-ci-note" role="alert">
          {rerun.message}
        </p>
      )}
      {rerun.phase === "started" && (
        <p className="gh-muted gh-ci-note" aria-live="polite">
          {t("github.checks.rerunStarted")}
        </p>
      )}
      {checks.truncated && <p className="gh-muted gh-ci-note">{t("github.checks.more")}</p>}
      {summary.total === 0 ? (
        <p className="gh-muted">{t("github.checks.none")}</p>
      ) : (
        <>
          <div className="gh-ci-summary">
            <div className="gh-ci-tally">
              {tally
                .filter(([, count]) => count > 0)
                .map(([state, count, label]) => (
                  <span key={state} className="gh-ci-count" data-check={state === "running" ? "pending" : state}>
                    <span className="gh-dot" aria-hidden="true" />
                    <span className="gh-count">{count}</span>
                    <span>{t(label)}</span>
                  </span>
                ))}
            </div>
            <span className="gh-muted gh-ci-progress-text">
              {strings.format("github.checks.done", String(summary.passed + summary.failed), String(summary.total))}
              {summary.eta != null &&
                summary.eta > 0 &&
                ` · ${strings.format("github.checks.eta", duration(summary.eta, strings.language))}`}
            </span>
          </div>
          {/* Each job's share of one bar, in the order the lists below go. */}
          <div className="gh-ci-bar" aria-hidden="true">
            {summary.failed > 0 && <span data-check="failed" style={{ flexGrow: summary.failed }} />}
            {summary.running > 0 && <span data-check="pending" style={{ flexGrow: summary.running }} />}
            {summary.queued > 0 && <span data-check="queued" style={{ flexGrow: summary.queued }} />}
            {summary.passed > 0 && <span data-check="passed" style={{ flexGrow: summary.passed }} />}
          </div>
          <div className="gh-ci-list" ref={list} onFocus={shown.onFocus}>
            {/* An empty grid row the band's columns are read from (useColumns). */}
            <ul className="gh-list gh-ci-rows gh-ci-probe" aria-hidden="true" />
            {shown.before > 0 && <div className="gh-ci-space" style={{ height: shown.before }} />}
            {shown.items.map(({ index, gap }) => {
              const item = items[index]!;
              return (
                <ItemView
                  key={item.key}
                  item={item}
                  index={index}
                  gap={gap}
                  measure={shown.measure}
                  strings={strings}
                  at={at}
                  open={open}
                  showPassed={showPassed}
                  passedCount={summary.passed}
                  togglePassed={togglePassed}
                />
              );
            })}
            {shown.after > 0 && <div className="gh-ci-space" style={{ height: shown.after }} />}
          </div>
        </>
      )}
    </section>
  );
}

/** One item: a group's title, the passed fold, or a line of rows (each a memoized CiRow). */
function ItemView({
  item,
  index,
  gap,
  measure,
  strings,
  at,
  open,
  showPassed,
  passedCount,
  togglePassed,
}: {
  item: DashboardItem;
  index: number;
  gap: number;
  measure: (node: HTMLElement | null) => void;
  strings: Strings;
  at: number;
  open: (url: string) => void;
  showPassed: boolean;
  passedCount: number;
  togglePassed: () => void;
}) {
  const shared = {
    ref: measure,
    "data-index": index,
    "data-size": itemSize(item),
    "data-gap": item.kind !== "line" && item.gap ? true : undefined,
    style: gap > 0 ? { marginTop: gap } : undefined,
  };
  if (item.kind === "title") {
    return (
      <div {...shared} className="gh-ci-item">
        <div className="gh-check-group-title">{strings.t(GROUP_TITLES[item.group])}</div>
      </div>
    );
  }
  if (item.kind === "fold") {
    return (
      <div {...shared} className="gh-ci-item" data-check="passed">
        <button type="button" className="gh-fold" aria-expanded={showPassed} onClick={togglePassed}>
          <Chevron open={showPassed} />
          <span className="gh-dot" aria-hidden="true" />
          <span>{strings.t("github.checks.passed")}</span>
          <span className="gh-count">{passedCount}</span>
        </button>
      </div>
    );
  }
  return (
    <ul {...shared} className="gh-ci-item gh-list gh-ci-rows">
      {item.rows.map((row, place) => (
        <li
          key={row.key}
          className="gh-ci-row"
          data-check={row.state === "running" ? "pending" : row.state}
          aria-posinset={item.first + place}
          aria-setsize={item.size}
        >
          {/* Only a row whose time runs reads the clock; every other row keeps its props across a tick. */}
          <CiRow row={row} strings={strings} at={liveRow(row) ? at : 0} open={open} />
        </li>
      ))}
    </ul>
  );
}

/** A row's line (its state's dot, its name as a link to the job, its workflow, its shards' pips, its
 *  time) and, for a failed row, each failed job's failure. Drawn again only when its props change. */
const CiRow = memo(function CiRow({
  row,
  strings,
  at,
  open,
}: {
  row: DashboardRow;
  strings: Strings;
  at: number;
  open: (url: string) => void;
}) {
  const first = row.jobs.find((job) => job.state === row.state) ?? row.jobs[0]!;
  const time = rowTime(row, at, strings);
  return (
    <>
      <div className="gh-ci-line">
        <span className="gh-dot" aria-hidden="true" />
        {first.url ? (
          <button type="button" className="gh-row-link" title={first.name} onClick={() => open(first.url!)}>
            {row.name}
          </button>
        ) : (
          <span className="gh-row-name">{row.name}</span>
        )}
        {row.workflow && <span className="gh-muted gh-ci-workflow">{row.workflow}</span>}
        {row.matrix && (
          <span className="gh-ci-pips">
            {row.jobs.map((job) => (
              <button
                key={job.id || job.name}
                type="button"
                className="gh-ci-pip"
                data-check={job.state === "running" ? "pending" : job.state}
                title={job.name}
                aria-label={job.name}
                onClick={() => job.url && open(job.url)}
              />
            ))}
          </span>
        )}
        {row.state === "failed" && row.jobs.some((job) => job.onBase) && (
          <span className="gh-muted gh-row-note">{strings.t("github.checks.onBase")}</span>
        )}
        {time && <span className="gh-ci-time">{time}</span>}
      </div>
      {row.state === "failed" &&
        row.jobs
          .filter((job) => job.state === "failed")
          .map((job) => <Failure key={job.id || job.name} job={job} row={row} strings={strings} />)}
    </>
  );
});

/** How many columns the band's grid lays rows in (styles.css: two on a wide band), read from an
 *  empty probe row when the list's width changes: one observer for the list, none per row. */
function useColumns(list: RefObject<HTMLElement | null>, drawn: boolean): number {
  const [columns, setColumns] = useState(1);
  useLayoutEffect(() => {
    const element = list.current;
    const probe = element?.querySelector<HTMLElement>(".gh-ci-probe");
    if (!element || !probe) return undefined;
    const read = () => {
      const tracks = getComputedStyle(probe).gridTemplateColumns.split(" ").filter(Boolean).length;
      setColumns(Math.max(1, tracks));
    };
    read();
    const resize = typeof ResizeObserver === "function" ? new ResizeObserver(read) : undefined;
    resize?.observe(element);
    return () => resize?.disconnect();
  }, [list, drawn]);
  return columns;
}

/** What the list draws: the indexes of the items in or near the viewport (all of them under
 *  WINDOW_ITEMS), each with the room the items not drawn just above it take (`gap`); the room above
 *  the first (`before`) and under the last (`after`); `measure`, each item's ref; and `onFocus`,
 *  the list's, which keeps the item holding the keyboard focus drawn. */
interface DashboardWindow {
  items: { index: number; gap: number }[];
  before: number;
  after: number;
  measure: (node: HTMLElement | null) => void;
  onFocus: (event: FocusEvent<HTMLElement>) => void;
}

/** Windows the dashboard's items over the page's scroll (TanStack's window virtualizer): a long
 *  dashboard mounts the items on screen and OVERSCAN either side and holds the rest as room, so the
 *  page is as tall, scrolls and keeps its place as with every row mounted. */
function useDashboardWindow(list: RefObject<HTMLElement | null>, items: readonly DashboardItem[]): DashboardWindow {
  const windowed = items.length > WINDOW_ITEMS;
  // Where the list starts on the page: what is above it (the header, the readiness block) grows as it loads.
  const [top, setTop] = useState(0);
  useLayoutEffect(() => {
    const element = list.current;
    if (!windowed || !element) return undefined;
    const place = () =>
      setTop(Math.round(element.getBoundingClientRect().top + (element.ownerDocument.defaultView?.scrollY ?? 0)));
    place();
    const resize = typeof ResizeObserver === "function" ? new ResizeObserver(place) : undefined;
    resize?.observe(element.closest("main") ?? element);
    return () => resize?.disconnect();
  }, [list, windowed]);
  const [focused, setFocused] = useState<number>();
  const onFocus = useCallback((event: FocusEvent<HTMLElement>) => {
    const index = Number((event.target as Element).closest("[data-index]")?.getAttribute("data-index"));
    setFocused(Number.isInteger(index) ? index : undefined);
  }, []);
  // One function per item list: TanStack asks every item's key again when it changes.
  const itemKey = useCallback((index: number) => items[index]!.key, [items]);
  // The first measured item of each kind sizes every one of that kind not yet drawn, so a scroll
  // that brings items in places them where estimated: TanStack moves every item under one whose
  // size differs from its guess.
  const sizes = useRef(new Map<DashboardSize, number>());
  const estimateSize = useCallback(
    (index: number) => {
      const kind = itemSize(items[index]!);
      return sizes.current.get(kind) ?? ESTIMATES[kind];
    },
    [items],
  );
  const measureSize = useCallback(
    (element: Element, entry: ResizeObserverEntry | undefined, instance: Virtualizer<Window, Element>) => {
      const size = measureElement(element, entry, instance);
      const kind = (element as HTMLElement).dataset.size as DashboardSize | undefined;
      if (kind && size > 0 && !sizes.current.has(kind)) sizes.current.set(kind, size);
      return size;
    },
    [],
  );
  const rangeExtractor = useCallback(
    (range: Range) => {
      const near = defaultRangeExtractor(range);
      if (focused === undefined || focused >= range.count || near.includes(focused)) return near;
      return [...near, focused].sort((a, b) => a - b);
    },
    [focused],
  );
  const virtualizer = useWindowVirtualizer({
    count: items.length,
    enabled: windowed,
    overscan: OVERSCAN,
    scrollMargin: top,
    estimateSize,
    getItemKey: itemKey,
    measureElement: measureSize,
    rangeExtractor,
  });
  const measure = windowed ? virtualizer.measureElement : noMeasure;
  if (!windowed) return { items: items.map((_, index) => ({ index, gap: 0 })), before: 0, after: 0, measure, onFocus };
  let end = top;
  let before = 0;
  const shown = virtualizer.getVirtualItems().map((item, at) => {
    const gap = Math.max(0, item.start - end);
    end = item.end;
    if (at === 0) before = gap;
    return { index: item.index, gap: at === 0 ? 0 : gap };
  });
  const after = Math.max(0, virtualizer.getTotalSize() + top - end);
  return { items: shown, before, after, measure, onFocus };
}

const noMeasure = () => {};

/** A running row's longest elapsed time (and what it usually takes); a finished one's duration. */
function rowTime(row: DashboardRow, at: number, strings: Strings): string | undefined {
  const jobs = row.state === "running" ? row.jobs.filter((job) => job.state === "running") : row.jobs;
  const seconds = Math.max(0, ...jobs.map((job) => elapsed(job, at)));
  if (!seconds) return undefined;
  const text = duration(seconds, strings.language);
  const expected = Math.max(0, ...jobs.map((job) => job.expected ?? 0));
  return row.state === "running" && expected
    ? strings.format("github.checks.usually", text, duration(expected, strings.language))
    : text;
}

/** A failed job's failing step and the end of its log, as the host read them. */
function Failure({ job, row, strings }: { job: DashboardJob; row: DashboardRow; strings: Strings }) {
  const step = job.failure?.step;
  const excerpt = job.failure?.excerpt;
  if (!step && !excerpt && !row.matrix) return null;
  return (
    <div className="gh-ci-failure">
      <div className="gh-ci-failure-head">
        {row.matrix && <span className="gh-ci-shard">{job.name}</span>}
        {step && <span>{strings.format("github.checks.step", step)}</span>}
      </div>
      {excerpt && <pre className="gh-ci-log">{excerpt}</pre>}
    </div>
  );
}

function Chevron({ open }: { open: boolean }) {
  return (
    <svg
      className="gh-chevron"
      data-open={open || undefined}
      width="12"
      height="12"
      viewBox="0 0 12 12"
      aria-hidden="true"
    >
      <path d="M4.5 2.5 8 6l-3.5 3.5" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
    </svg>
  );
}
