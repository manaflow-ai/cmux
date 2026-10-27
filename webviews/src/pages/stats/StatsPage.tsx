// The Stats page (hq#1920): what this machine's agents did, from the local session logs only.
// Tiles first (agent time, time waiting on you, turns, peak parallel agents, streak), then the
// activity heatmap, the time of day, each agent's share, how turns ended and what needed you.
import { useSyncExternalStore } from "react";
import type { Strings } from "../shared/i18n";
import { harnessName } from "./harnessNames";
import {
  attentionRows,
  formatCount,
  formatDay,
  formatDays,
  formatDuration,
  formatHour,
  formatWait,
  heatmap,
  hourShares,
  stripLabel,
} from "./shape";
import type { StatsStore } from "./store";
import { RANGES, type StatsSummary } from "./types";

export function StatsPage({ store, strings }: { store: StatsStore; strings: Strings }) {
  const snapshot = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const { summary, range } = snapshot;

  if (snapshot.unavailable) return <p className="stats-message">{strings.t("stats.page.unavailable")}</p>;

  return (
    <div className="stats">
      <header className="stats-header">
        <div>
          <h1 className="stats-title">{strings.t("stats.page.title")}</h1>
          <p className="stats-private">{strings.t("stats.page.private")}</p>
        </div>
        <fieldset className="stats-ranges" aria-label={strings.t("stats.range.label")}>
          {RANGES.map((option) => (
            <button
              key={option}
              type="button"
              aria-pressed={option === range}
              className={option === range ? "stats-range is-selected" : "stats-range"}
              onClick={() => void store.setRange(option)}
            >
              {strings.t(`stats.range.${option}`)}
            </button>
          ))}
        </fieldset>
      </header>
      {snapshot.failed ? (
        <p className="stats-message">{snapshot.failed.message ?? strings.t("stats.page.failed")}</p>
      ) : !summary ? (
        <p className="stats-message stats-muted">{strings.t("stats.page.loading")}</p>
      ) : (
        <Summary summary={summary} strings={strings} />
      )}
    </div>
  );
}

function Summary({ summary, strings }: { summary: StatsSummary; strings: Strings }) {
  const language = strings.language;
  // The range this summary covers: while another range loads, the old summary keeps its own grid.
  const range = Math.round((summary.until - summary.since) / 86_400_000);
  const count = (value: number) => formatCount(value, language);
  const duration = (ms: number) => formatDuration(ms, language);
  const empty = summary.turns === 0 && summary.workingMs === 0;
  const attention = attentionRows(summary);
  const ratio = new Intl.NumberFormat(language, { maximumFractionDigits: 2 });
  const cells = heatmap(summary.days, summary.until, summary.tzOffsetMinutes, range);
  const days = cells.filter((cell) => cell.day);
  const tiles: { key: string; value: string; detail?: string }[] = [
    { key: "stats.tile.agentTime", value: duration(summary.workingMs) },
    { key: "stats.tile.waiting", value: duration(summary.waitingMs) },
    { key: "stats.tile.turns", value: count(summary.turns) },
    { key: "stats.tile.peak", value: count(summary.peakParallel) },
    {
      key: "stats.tile.streak",
      value: formatDays(summary.streak.current, language),
      detail: strings.format("stats.tile.longest", formatDays(summary.streak.longest, language)),
    },
    { key: "stats.tile.sessions", value: count(summary.sessions) },
    { key: "stats.tile.toolCalls", value: count(summary.toolCalls) },
    { key: "stats.tile.steers", value: count(summary.steers) },
    { key: "stats.tile.approvals", value: count(summary.permissionRequests) },
  ];
  return (
    <>
      <section className="stats-tiles">
        {tiles.map((tile) => (
          <div key={tile.key} className="stats-tile">
            <div className="stats-tile-label">{strings.t(tile.key)}</div>
            <div className="stats-tile-value">{tile.value}</div>
            {tile.detail && <div className="stats-tile-detail">{tile.detail}</div>}
          </div>
        ))}
      </section>
      {empty && <p className="stats-message stats-muted">{strings.t("stats.page.empty")}</p>}
      <section className="stats-section">
        <h2 className="stats-section-title">{strings.t("stats.section.activity")}</h2>
        {range > 31 ? (
          <div className="stats-heatmap">
            {cells.map((cell, index) => (
              <div
                key={cell.day ?? `pad-${index}`}
                className={cell.day ? `stats-heat stats-heat-${cell.level}` : "stats-heat is-padding"}
                title={cell.day ? `${formatDay(cell.day, language)} · ${duration(cell.workingMs)}` : undefined}
              />
            ))}
          </div>
        ) : (
          // A week or a month is too few columns for the weekday grid: one row of days fills the width.
          <div className="stats-days">
            {days.map((cell, index) => (
              <div
                key={cell.day}
                className="stats-day"
                // tooltip-allow: the day shows a short label; the tooltip is its date and working time
                title={`${formatDay(cell.day!, language)} · ${duration(cell.workingMs)}`}
              >
                <div className={`stats-heat stats-heat-${cell.level}`} />
                <span className="stats-day-label">
                  {stripLabel(cell.day!, days.length - 1 - index, range, language)}
                </span>
              </div>
            ))}
          </div>
        )}
      </section>
      <section className="stats-section">
        <h2 className="stats-section-title">{strings.t("stats.section.hours")}</h2>
        <div className="stats-hours">
          {hourShares(summary.hours).map((share, hour) => (
            <div
              key={hour}
              className="stats-hour"
              title={`${formatHour(hour, language)} · ${duration(summary.hours[hour] ?? 0)}`}
            >
              <div className="stats-hour-bar" style={{ height: `${Math.round(share * 100)}%` }} />
            </div>
          ))}
        </div>
      </section>
      {summary.harnesses.length > 0 && (
        <section className="stats-section">
          <h2 className="stats-section-title">{strings.t("stats.section.harnesses")}</h2>
          <ul className="stats-harnesses">
            {summary.harnesses.map((harness) => (
              <li key={harness.harness} className="stats-harness">
                <span className="stats-harness-name">{harnessName(harness.harness)}</span>
                <span className="stats-harness-track">
                  <span
                    className="stats-harness-bar"
                    style={{ width: `${Math.round((100 * harness.workingMs) / Math.max(1, summary.workingMs))}%` }}
                  />
                </span>
                <span className="stats-harness-value">{duration(harness.workingMs)}</span>
                <span className="stats-harness-value stats-muted">{count(harness.turns)}</span>
              </li>
            ))}
          </ul>
        </section>
      )}
      <section className="stats-section">
        <h2 className="stats-section-title">{strings.t("stats.section.outcomes")}</h2>
        <dl className="stats-outcomes">
          {(
            [
              ["stats.outcome.completed", summary.turnsCompleted],
              ["stats.outcome.cancelled", summary.turnsCancelled],
              ["stats.outcome.failed", summary.turnsFailed],
            ] as const
          ).map(([key, value]) => (
            <div key={key} className="stats-outcome">
              <dt>{strings.t(key)}</dt>
              <dd>{count(value)}</dd>
            </div>
          ))}
        </dl>
      </section>
      {attention.length > 0 && (
        <section className="stats-section stats-attention">
          <h2 className="stats-section-title">{strings.t("stats.section.attention")}</h2>
          <dl className="stats-outcomes">
            {attention.map((row) => (
              <div key={row.key} className="stats-outcome">
                <dt>{strings.t(row.key)}</dt>
                <dd>
                  {"wait" in row
                    ? formatWait(row.wait, language)
                    : "count" in row
                      ? count(row.count)
                      : ratio.format(row.ratio)}
                </dd>
              </div>
            ))}
          </dl>
        </section>
      )}
    </>
  );
}
