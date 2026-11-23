// Team's Overview and Per PR views (TeamAuditScreen.tsx). Overview: a tile per measure the answer
// carries, with its value over the range and a bar per day under it (the reply grouped by day, in
// day order). Per PR: agent time and cost as time per landed pull request, by project and by person,
// longest first, a row at twice the team's agent time per PR or more (or one the platform flags)
// marked as an outlier. The platform sums every number; these only divide a row's own two numbers
// for display and scale bars to the longest one shown.
import type { CSSProperties } from "react";
import type { StringKey, Translate } from "../i18n";
import { formatCount, formatDuration } from "../ledger/ledgerModel";
import { agentMs, readStatus, rowName, type AuditRead } from "./teamAuditRead";
import { auditHasRows, auditTokensIn, formatHitRate, type TeamAuditRow, type TeamAuditTotals } from "./teamAuditModel";
import { USAGE_OTHERS_KEY, type UsageExportTotals } from "./usageExport";

const MINUTE = 60_000;

type Tile = {
  label: StringKey;
  /// The range's value, undefined when the answer does not carry the measure (no tile).
  total(totals: TeamAuditTotals & UsageExportTotals, locale: string): string | undefined;
  /// One day's value for the bars, null for a day with nothing to say.
  day(row: TeamAuditRow): number | null;
};

const perPr = (minutes: number | undefined, prs: number | undefined) =>
  minutes !== undefined && prs ? minutes / prs : undefined;

const TILES: Tile[] = [
  {
    label: "teamAudit.total.tokens",
    total: (totals, locale) => formatCount(auditTokensIn(totals) + totals.outputTokens, locale),
    day: (row) => auditTokensIn(row) + row.outputTokens,
  },
  {
    label: "ledger.total.time",
    total: (totals, locale) => formatDuration(agentMs(totals), locale),
    day: (row) => agentMs(row),
  },
  {
    label: "teamAudit.total.prs",
    total: (totals, locale) => (totals.prsLanded === undefined ? undefined : formatCount(totals.prsLanded, locale)),
    day: (row) => row.prsLanded ?? null,
  },
  {
    label: "teamAudit.total.perPr",
    total: (totals, locale) =>
      totals.minutesPerPr === undefined ? undefined : formatDuration(totals.minutesPerPr * MINUTE, locale),
    day: (row) => perPr(row.agentMinutes, row.prsLanded) ?? null,
  },
  {
    label: "teamAudit.total.vmTime",
    total: (totals, locale) =>
      totals.vmVcpuSeconds === undefined ? undefined : formatDuration(totals.vmVcpuSeconds * 1000, locale),
    day: (row) => row.vmVcpuSeconds ?? null,
  },
  {
    // An audit answer's cloud machine time, where the export's VM time is not there.
    label: "teamAudit.total.machineTime",
    total: (totals, locale) =>
      totals.vmVcpuSeconds !== undefined || totals.machineMs === undefined
        ? undefined
        : formatDuration(totals.machineMs, locale),
    day: (row) => row.machineMs ?? null,
  },
  {
    label: "teamAudit.total.ciTime",
    total: (totals, locale) =>
      totals.ciMinutes === undefined ? undefined : formatDuration(totals.ciMinutes * MINUTE, locale),
    day: (row) => row.ciMinutes ?? null,
  },
  {
    label: "teamAudit.total.hitRate",
    total: (totals, locale) => formatHitRate(totals.cacheHitRate, locale),
    day: (row) => row.cacheHitRate,
  },
];

export function OverviewView({ read, locale, t }: { read: AuditRead; locale: string; t: Translate }) {
  const reply = read.reply;
  // Day keys are YYYY-MM-DD, so their text order is their day order.
  const days = reply ? [...reply.rows].sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : 0)) : [];
  const tiles = reply
    ? TILES.flatMap((tile) => {
        const value = tile.total(reply.totals, locale);
        return value === undefined ? [] : [{ tile, value }];
      })
    : // Before the first answer the audit's tiles hold their place with dashes.
      TILES.filter((tile) =>
        ["teamAudit.total.tokens", "ledger.total.time", "teamAudit.total.hitRate"].includes(tile.label),
      ).map((tile) => ({ tile, value: "–" }));
  const status = readStatus(read, t);
  return (
    <div className="cst-scroll tma-scroll">
      <dl className="tma-kpis">
        {tiles.map(({ tile, value }) => (
          <div key={tile.label} className="cst-tile tma-kpi">
            <dt>{t(tile.label)}</dt>
            <dd>{value}</dd>
            {days.length > 1 && (
              <dd className="tma-spark-cell">
                <Spark values={days.map(tile.day)} label={t("teamAudit.trend", { measure: t(tile.label) })} />
              </dd>
            )}
          </div>
        ))}
      </dl>
      {status && (
        <div className="cst-status" aria-live="polite">
          {status}
          {read.result?.kind === "failed" && (
            <button type="button" className="cst-link" onClick={read.retry}>
              {t("ledger.retry")}
            </button>
          )}
        </div>
      )}
    </div>
  );
}

/// A bar per day, scaled to the range's highest day; a day with nothing is a gap.
function Spark({ values, label }: { values: (number | null)[]; label: string }) {
  const high = Math.max(0, ...values.map((value) => value ?? 0));
  return (
    <svg className="tma-spark" aria-label={label} viewBox={`0 0 ${values.length * 4} 24`} preserveAspectRatio="none">
      {values.map((value, index) => {
        if (value === null || high === 0) return null;
        const height = Math.max(1, (value / high) * 24);
        return <rect key={index} x={index * 4} y={24 - height} width={3} height={height} rx={0.5} />;
      })}
    </svg>
  );
}

export function EfficiencyView({
  projects,
  people,
  locale,
  t,
}: {
  projects: AuditRead;
  people: AuditRead;
  locale: string;
  t: Translate;
}) {
  return (
    <div className="cst-scroll tma-scroll tma-eff">
      <PerPrTable title="teamAudit.efficiency.byProject" read={projects} locale={locale} t={t} />
      <PerPrTable title="teamAudit.efficiency.byPerson" read={people} locale={locale} t={t} />
      <p className="tma-eff-note">
        <span className="tma-outlier-mark" aria-hidden />
        {t("teamAudit.efficiency.outlierNote")}
      </p>
    </div>
  );
}

type PerPrLine = { row: TeamAuditRow; prs: number; agent?: number; cost?: number; outlier: boolean };

function perPrLines(rows: readonly TeamAuditRow[], team: number | undefined): PerPrLine[] {
  const lines = rows.map((row): PerPrLine => {
    const prs = row.prsLanded ?? 0;
    const agent = perPr(row.agentMinutes ?? row.wallMs / MINUTE, prs);
    const cost = perPr(row.costAsTimeMinutes, prs);
    const outlier =
      row.outlier === true || (agent !== undefined && team !== undefined && team > 0 && agent >= team * 2);
    return { row, prs, outlier, ...(agent !== undefined ? { agent } : {}), ...(cost !== undefined ? { cost } : {}) };
  });
  // Longest agent time per PR first; rows with no landed PR after them, by agent time.
  return lines.sort((a, b) =>
    a.agent !== undefined && b.agent !== undefined
      ? b.agent - a.agent
      : a.agent !== undefined
        ? -1
        : b.agent !== undefined
          ? 1
          : agentMs(b.row) - agentMs(a.row),
  );
}

function PerPrTable({ title, read, locale, t }: { title: StringKey; read: AuditRead; locale: string; t: Translate }) {
  const reply = read.reply;
  const lines = reply && auditHasRows(reply) ? perPrLines(reply.rows, reply.totals.minutesPerPr) : [];
  const longest = Math.max(0, ...lines.map((line) => line.agent ?? 0));
  const status = readStatus(read, t);
  const group = reply?.groupBy ?? "project";
  return (
    <section className="tma-eff-section">
      <h3 className="tma-eff-title">{t(title)}</h3>
      {lines.length > 0 && (
        <table className="tma-table tma-eff-table">
          <thead>
            <tr>
              <th scope="col" className="tma-key">
                <span className="tma-key-text">
                  {t(title === "teamAudit.efficiency.byProject" ? "teamAudit.group.project" : "teamAudit.group.person")}
                </span>
              </th>
              <th scope="col">{t("teamAudit.total.prs")}</th>
              <th scope="col" className="tma-bar-col">
                {t("teamAudit.total.perPr")}
              </th>
              <th scope="col">{t("teamAudit.total.costPerPr")}</th>
            </tr>
          </thead>
          <tbody>
            {lines.map((line) => (
              <tr
                key={`${group}:${line.row.key}`}
                data-outlier={line.outlier || undefined}
                data-others={line.row.key === USAGE_OTHERS_KEY || undefined}
              >
                <th scope="row" className="tma-key">
                  <span className="tma-key-text">
                    {rowName(group, line.row, locale, t)}
                    {line.outlier && <span className="tma-outlier">{t("teamAudit.efficiency.outlier")}</span>}
                  </span>
                </th>
                <td>{formatCount(line.prs, locale)}</td>
                <td className="tma-bar-col">
                  <span
                    className="tma-bar-cell"
                    style={{ "--tma-share": longest > 0 ? (line.agent ?? 0) / longest : 0 } as CSSProperties}
                  >
                    {line.agent === undefined ? "–" : formatDuration(line.agent * MINUTE, locale)}
                  </span>
                </td>
                <td>{line.cost === undefined ? "–" : formatDuration(line.cost * MINUTE, locale)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
      {status && (
        <div className="cst-status" aria-live="polite">
          {status}
          {read.result?.kind === "failed" && (
            <button type="button" className="cst-link" onClick={read.retry}>
              {t("ledger.retry")}
            </button>
          )}
        </div>
      )}
    </section>
  );
}
