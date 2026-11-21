// Cloud start timings (DEV and NIGHTLY, the Cloud page's `#/timings`): one Cloud start as a waterfall
// (a row per hop, each bar at its offset from the start), each hop's p50 and p95 over the last day,
// and the last day's starts to pick from. Data: the Cloud app server's `cloud.start_trace.list` and
// `cloud.start_trace.get` (startTraceStore.ts), the platform's JSON verbatim. A start begins at the
// server's receipt of the create: the app's click is not timed yet, so `click` is a row only when a
// client (the CLI, a journey) posted a span for it.
//
// Three looks for the gallery (design/cloud-start-timings.md); `bands` is the one the page uses.
// - `lanes`: the waterfall, then a separate table of the day's p50 and p95.
// - `bands`: each row also draws the day's p50 to p95 behind its bar, and its numbers beside it.
// - `columns`: the starts in a list beside a `lanes` waterfall.
import { useSyncExternalStore } from "react";
import type { Strings } from "../shared/i18n";
import { format, L } from "./strings";
import type { StartTraceStore } from "./startTraceStore";
import {
  axisTicks,
  formatDuration,
  waterfall,
  type HopRow,
  type StartTraceList,
  type StartTraceSummary,
  type Waterfall,
} from "./startTraces";

export type StartTimingsLook = "lanes" | "bands" | "columns";

export const DEFAULT_TIMINGS_LOOK: StartTimingsLook = "bands";

const pct = (value: number, span: number) => `${Math.min(100, Math.max(0, (value / span) * 100))}%`;

function ago(at: number, now: number, locale: string): string {
  const minutes = Math.round((at - now) / 60_000);
  const rtf = new Intl.RelativeTimeFormat(locale, { numeric: "auto", style: "short" });
  if (Math.abs(minutes) < 60) return rtf.format(minutes, "minute");
  return rtf.format(Math.round(minutes / 60), "hour");
}

function Axis({ chart, locale }: { chart: Waterfall; locale: string }) {
  return (
    <div className="st-row st-axis" aria-hidden="true">
      <span className="st-hop" />
      <span className="st-track">
        {axisTicks(chart.span).map((tick) => (
          <span key={tick} className="st-tick" style={{ left: pct(tick, chart.span) }}>
            <span className="st-tick-label">{formatDuration(tick, locale)}</span>
          </span>
        ))}
      </span>
      <span className="st-value" />
    </div>
  );
}

function segmentTitle(
  row: HopRow,
  offset: number,
  length: number,
  source: string,
  part: string | undefined,
  t: Strings["t"],
  locale: string,
) {
  const at = format(t(L.timingsAt), { offset: formatDuration(offset, locale) });
  const by = format(t(L.timingsMeasuredBy), { source: part ? `${source} (${part})` : source });
  return `${row.hop}: ${formatDuration(length, locale)}. ${at}. ${by}.`;
}

function HopLine({
  row,
  chart,
  bands,
  strings,
  locale,
}: {
  row: HopRow;
  chart: Waterfall;
  bands: boolean;
  strings: Strings;
  locale: string;
}) {
  const { t } = strings;
  const stats = row.stats;
  const band =
    bands && row.segments.length === 1 && row.offset !== null && stats?.p95_ms != null ? (
      <span
        className="st-band"
        style={{ left: pct(row.offset, chart.span), width: pct(stats.p95_ms, chart.span) }}
        aria-hidden="true"
      >
        {stats.p50_ms != null && (
          <span className="st-p50" style={{ left: `${(stats.p50_ms / stats.p95_ms) * 100}%` }} />
        )}
      </span>
    ) : null;
  return (
    <div
      className="st-row"
      data-hop={row.hop}
      data-slow={row.slow || undefined}
      data-missing={row.duration === null || undefined}
    >
      <span className="st-hop">{row.hop}</span>
      <span className="st-track">
        {band}
        {row.segments.map((segment, index) => (
          <span
            key={index}
            className="st-bar"
            data-source={segment.source === "platform" ? "server" : "client"}
            style={{ left: pct(segment.offset, chart.span), width: pct(segment.length, chart.span) }}
            title={segmentTitle(row, segment.offset, segment.length, segment.source, segment.part, t, locale)}
          />
        ))}
      </span>
      <span className="st-value">
        {row.duration === null ? (
          <span className="st-missing">{t(L.timingsMissing)}</span>
        ) : (
          <span className="st-duration">{formatDuration(row.duration, locale)}</span>
        )}
        {bands && stats && (
          <span className="st-stats">
            {format(t(L.timingsP50P95), {
              median: formatDuration(stats.p50_ms, locale),
              high: formatDuration(stats.p95_ms, locale),
            })}
          </span>
        )}
        {row.slow && (
          <span className="st-slow">
            <span className="st-slow-dot" aria-hidden="true" />
            {t(L.timingsSlow)}
          </span>
        )}
      </span>
    </div>
  );
}

function Legend({ strings }: { strings: Strings }) {
  const { t } = strings;
  return (
    <div className="st-legend">
      <span className="st-key">
        <span className="st-swatch" data-source="server" aria-hidden="true" />
        {t(L.timingsServer)}
      </span>
      <span className="st-key">
        <span className="st-swatch" data-source="client" aria-hidden="true" />
        {t(L.timingsClient)}
      </span>
    </div>
  );
}

function StatsTable({ list, strings, locale }: { list: StartTraceList; strings: Strings; locale: string }) {
  const { t } = strings;
  const hops = Object.entries(list.hops).filter(
    (entry): entry is [string, NonNullable<(typeof entry)[1]>] => !!entry[1],
  );
  return (
    <table className="st-table">
      <caption className="cloud-section-title">{t(L.timingsDay)}</caption>
      <thead>
        <tr>
          <th scope="col">{t(L.timingsHop)}</th>
          <th scope="col">{t(L.timingsSamples)}</th>
          <th scope="col">p50</th>
          <th scope="col">p95</th>
        </tr>
      </thead>
      <tbody>
        {hops.map(([hop, stats]) => (
          <tr key={hop} data-hop={hop}>
            <th scope="row">{hop}</th>
            <td>{stats.n}</td>
            <td>{formatDuration(stats.p50_ms, locale)}</td>
            <td>{formatDuration(stats.p95_ms, locale)}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

function StartList({
  traces,
  selected,
  onSelect,
  now,
  strings,
  locale,
}: {
  traces: StartTraceSummary[];
  selected?: string;
  onSelect(trace: string): void;
  now: number;
  strings: Strings;
  locale: string;
}) {
  const { t } = strings;
  return (
    <section className="st-starts" aria-label={t(L.timingsRecent)}>
      <h2 className="cloud-section-title">{t(L.timingsRecent)}</h2>
      {traces.length === 0 ? (
        <p className="st-empty">{t(L.timingsEmpty)}</p>
      ) : (
        <ul className="st-start-list">
          {traces.map((one) => (
            <li key={one.trace}>
              <button
                type="button"
                className="st-start"
                aria-current={one.trace === selected || undefined}
                data-trace={one.trace}
                onClick={() => onSelect(one.trace)}
              >
                <span className="st-start-when">{ago(one.started_at, now, locale)}</span>
                <span className="st-start-path">{one.path ?? "–"}</span>
                <span className="st-start-machine">{one.machine ?? "–"}</span>
                <span className="st-start-total">{formatDuration(one.total_ms, locale)}</span>
              </button>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

export function StartTimings({
  store,
  strings,
  look = DEFAULT_TIMINGS_LOOK,
  now = Date.now(),
}: {
  store: StartTraceStore;
  strings: Strings;
  look?: StartTimingsLook;
  /** The clock the start list's "3 min ago" reads (the gallery pins it). */
  now?: number;
}) {
  const snap = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const { t } = strings;
  const locale = strings.language;
  const list = snap.list;
  const chart = snap.trace ? waterfall(snap.trace, list?.hops) : null;
  const bands = look === "bands";
  const traces = list?.traces ?? [];
  const startList = (
    <StartList
      traces={traces}
      selected={snap.selected}
      onSelect={(id) => void store.select(id)}
      now={now}
      strings={strings}
      locale={locale}
    />
  );
  const figure = chart && snap.trace && (
    <section className="st-waterfall" aria-label={snap.trace.trace}>
      <div className="st-waterfall-header">
        <h2 className="cloud-section-title st-trace-id">{snap.trace.trace}</h2>
        <span className="st-total">
          {format(t(L.timingsTotal), { total: formatDuration(snap.trace.total_ms, locale) })}
        </span>
      </div>
      {!chart.clicked && <p className="st-note">{t(L.timingsNoClick)}</p>}
      <Legend strings={strings} />
      <div className="st-chart" data-look={look}>
        <Axis chart={chart} locale={locale} />
        {chart.rows.map((row) => (
          <HopLine key={row.hop} row={row} chart={chart} bands={bands} strings={strings} locale={locale} />
        ))}
      </div>
    </section>
  );
  return (
    <div className="st-page" data-look={look} data-loading={snap.loading || undefined}>
      <div className="st-toolbar">
        <h2 className="st-heading">{t(L.timingsTitle)}</h2>
        <button
          type="button"
          className="cloud-button st-refresh"
          onClick={() => void store.refresh()}
          disabled={snap.loading}
        >
          {t(L.timingsRefresh)}
        </button>
      </div>
      {snap.error && (
        <div className="cloud-error" role="alert">
          <span className="cloud-error-text">
            <span>{t(L.timingsFailed)}</span>
            <span className="cloud-error-detail">{snap.error}</span>
          </span>
        </div>
      )}
      {look === "columns" ? (
        <div className="st-columns">
          {startList}
          <div className="st-main">
            {figure}
            {list && <StatsTable list={list} strings={strings} locale={locale} />}
          </div>
        </div>
      ) : (
        <>
          {figure}
          {list && look === "lanes" && <StatsTable list={list} strings={strings} locale={locale} />}
          {startList}
        </>
      )}
    </div>
  );
}
