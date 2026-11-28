// Team (History > Team, behind the `team-audit` experiment): the team's agent spend from the turns
// teammates share (teamAuditModel.ts), as an engineering leader reads it. Three views over one range:
// Overview (a tile per measure with its trend by day), Breakdown (the table: a column per measure,
// grouped by team, project, person, model and on, a row click drilling into its slice) and Per PR
// (agent time and cost as time per landed pull request, by project and by person, outliers marked).
// Export saves what the view shows: CSV through acpmux to Downloads, JSON (the answer on screen)
// through the host's save panel. Every number is the platform's; the page formats and orders them.
// Built like History > Costs (ledger/LedgerScreen.tsx) and with its formatters; spend reads as time.
import { useRef, useState } from "react";
import { Menu, MenuButton, MenuItem, MenuPopup } from "../../../ui/Menu";
import { Select } from "../../../ui/Select";
import { Tabs, TabsList, TabsTrigger } from "../../../ui/Tabs";
import { currentLanguage, useT, type StringKey, type Translate } from "../i18n";
import type { LedgerSaveOutcome } from "../ledger/LedgerScreen";
import { formatCount, formatDuration, type LedgerExportKind } from "../ledger/ledgerModel";
import {
  agentMs,
  GROUP_KEY,
  REASON_KEY,
  readStatus,
  rowName,
  useAuditRead,
  type AuditRead,
  type Load,
} from "./teamAuditRead";
import {
  auditHasMachineTime,
  auditHasRows,
  auditTokensIn,
  formatHitRate,
  readTeamAuditSaved,
  TEAM_AUDIT_GROUPS,
  TEAM_AUDIT_NONE,
  TEAM_AUDIT_RANGES,
  teamAuditParams,
  type TeamAuditRange,
  type TeamAuditReply,
  type TeamAuditRow,
  type TeamAuditTotals,
} from "./teamAuditModel";
import { EfficiencyView, OverviewView } from "./TeamAuditViews";
import {
  USAGE_DRILL_ORDER,
  USAGE_EXPORT_GROUPS,
  USAGE_OTHERS_KEY,
  usageGroupAllowed,
  type UsageDrillStep,
  type UsageGroup,
} from "./usageExport";
import "../ledger/ledger.css";
import "./teamAudit.css";

export const TEAM_AUDIT_VIEWS = ["overview", "breakdown", "efficiency"] as const;
export type TeamAuditView = (typeof TEAM_AUDIT_VIEWS)[number];

type Props = {
  /// `_acpmux/team_audit` with `params` (direct.ts `teamAudit`).
  load: Load;
  /// The platform's usage export (usageExport.ts `USAGE_EXPORT_METHOD`, a stub acpmux does not
  /// serve yet). Set, every read goes through it and the page offers team and project rows, PRs,
  /// CI and VM time, drill-down and Per PR; unset, the audit's measures only.
  loadUsage?: Load;
  /// Saves a file (queue/historyPages.ts: the host's save panel, else the clipboard). Unset: no JSON.
  save?(text: string, suggestedName: string, kind: LedgerExportKind): Promise<LedgerSaveOutcome>;
  initialView?: TeamAuditView;
  initialRange?: TeamAuditRange;
  initialGroup?: UsageGroup;
  /// Breakdown starts inside these slices (the gallery).
  initialDrill?: UsageDrillStep[];
  /// The Export menu starts open (the gallery).
  initialExportOpen?: boolean;
  now?: number;
};

const RANGE_KEY: Record<TeamAuditRange, StringKey> = {
  "7d": "ledger.range.7d",
  "30d": "ledger.range.30d",
  "90d": "teamAudit.range.90d",
};
const VIEW_KEY: Record<TeamAuditView, StringKey> = {
  overview: "teamAudit.view.overview",
  breakdown: "teamAudit.view.breakdown",
  efficiency: "teamAudit.view.efficiency",
};
const whereOf = (drill: readonly UsageDrillStep[]) =>
  drill.length > 0 ? Object.fromEntries(drill.map((step) => [step.group, step.key])) : undefined;

export function TeamAuditScreen({
  load,
  loadUsage,
  save,
  initialView = "breakdown",
  initialRange = "30d",
  initialGroup = "person",
  initialDrill = [],
  initialExportOpen,
  now,
}: Props) {
  const t = useT();
  const locale = currentLanguage();
  const [today] = useState(() => now ?? Date.now());
  const [view, setView] = useState<TeamAuditView>(
    loadUsage || initialView !== "efficiency" ? initialView : "breakdown",
  );
  const [range, setRange] = useState<TeamAuditRange>(initialRange);
  const [group, setGroup] = useState<UsageGroup>(initialGroup);
  const [drill, setDrill] = useState<UsageDrillStep[]>(initialDrill);
  const [notice, setNotice] = useState<{ text: string; tone: "ok" | "error" } | undefined>();
  // A pick counts at once in `picks` and in the next render's `drawn`: an export clicked between the
  // two (the old render's handler) holds a reply for what is no longer picked, so it saves nothing.
  const picks = useRef(0);
  const [drawn, setDrawn] = useState(0);
  const moved = () => {
    picks.current += 1;
    setDrawn(picks.current);
  };
  const read = loadUsage ?? load;
  const day = now ?? today;

  // What the view reads first; Per PR reads by person too.
  const primary = (() => {
    if (view === "overview") return teamAuditParams(range, "day", day);
    if (view === "efficiency") return teamAuditParams(range, "project", day);
    return teamAuditParams(range, group, day, "json", loadUsage ? whereOf(drill) : undefined);
  })();
  const main = useAuditRead(read, primary);
  const people = useAuditRead(read, view === "efficiency" ? teamAuditParams(range, "person", day) : undefined);

  const privacy = main.reply?.privacy;
  const groups: readonly UsageGroup[] = loadUsage
    ? USAGE_EXPORT_GROUPS.filter((each) => each === group || usageGroupAllowed(each, privacy))
    : TEAM_AUDIT_GROUPS;
  const views = TEAM_AUDIT_VIEWS.filter((each) => each !== "efficiency" || loadUsage);

  // Export saves the answer on screen, and only once it is the answer for what is picked.
  const shown = main.result?.kind === "ready" ? main.result.reply : undefined;
  const csv = () => {
    if (!shown || picks.current !== drawn) return;
    const params = { ...primary, format: "csv" };
    // The reply's own days: the file holds what the page holds.
    if (shown.range.since && shown.range.until) Object.assign(params, shown.range);
    setNotice(undefined);
    read(params).then(
      (value) => {
        const answer = readTeamAuditSaved(value);
        setNotice(
          answer.kind === "saved"
            ? { text: t("teamAudit.saved", { path: answer.path }), tone: "ok" }
            : { text: t(REASON_KEY[answer.kind]), tone: "error" },
        );
      },
      () => setNotice({ text: t("teamAudit.failed"), tone: "error" }),
    );
  };
  const json = async () => {
    if (!shown || !save || picks.current !== drawn) return;
    setNotice(undefined);
    const name = `cmux-usage-${shown.range.since}-${shown.range.until}-${shown.groupBy}.json`;
    try {
      const outcome = await save(`${JSON.stringify(shown, null, 2)}\n`, name, "json");
      if (outcome !== "cancelled") setNotice({ text: t(`ledger.export.${outcome}`), tone: "ok" });
    } catch {
      setNotice({ text: t("ledger.export.failed"), tone: "error" });
    }
  };

  const pick = (next: { range?: TeamAuditRange; group?: UsageGroup; view?: TeamAuditView }) => {
    moved();
    setNotice(undefined);
    if (next.range) setRange(next.range);
    if (next.view) setView(next.view);
    if (next.group) {
      setGroup(next.group);
      setDrill([]);
    }
  };
  // A row click reads its slice by the next grouping of the drill order (an export read only).
  const nextGroup = (from: UsageGroup) => {
    const at = USAGE_DRILL_ORDER.indexOf(from);
    const next = at >= 0 ? USAGE_DRILL_ORDER[at + 1] : undefined;
    return next && usageGroupAllowed(next, privacy) ? next : undefined;
  };
  const drillInto =
    loadUsage && view === "breakdown" && shown && nextGroup(shown.groupBy)
      ? (row: TeamAuditRow) => {
          const next = nextGroup(shown.groupBy);
          if (!next || row.key === USAGE_OTHERS_KEY || row.key === TEAM_AUDIT_NONE) return;
          moved();
          setNotice(undefined);
          setDrill((steps) => [
            ...steps,
            { group: shown.groupBy, key: row.key, label: rowName(shown.groupBy, row, locale, t) },
          ]);
          setGroup(next);
        }
      : undefined;
  const backTo = (index: number) => {
    const step = drill[index];
    if (!step) return;
    moved();
    setNotice(undefined);
    setDrill(drill.slice(0, index));
    setGroup(step.group);
  };

  const privacyNote =
    privacy === "org" ? t("teamAudit.privacy.org") : privacy === "team" ? t("teamAudit.privacy.team") : undefined;
  const loading = main.loading || people.loading;

  return (
    <div className="cst tma" data-loading={loading || undefined} data-view={view}>
      <div className="cst-controls">
        <Tabs variant="segmented" value={view} onValueChange={(value) => pick({ view: value as TeamAuditView })}>
          <TabsList aria-label={t("teamAudit.view")}>
            {views.map((each) => (
              <TabsTrigger key={each} value={each}>
                {t(VIEW_KEY[each])}
              </TabsTrigger>
            ))}
          </TabsList>
        </Tabs>
        <Tabs variant="segmented" value={range} onValueChange={(value) => pick({ range: value as TeamAuditRange })}>
          <TabsList aria-label={t("ledger.range")}>
            {TEAM_AUDIT_RANGES.map((each) => (
              <TabsTrigger key={each} value={each}>
                {t(RANGE_KEY[each])}
              </TabsTrigger>
            ))}
          </TabsList>
        </Tabs>
        <span className="cst-fill" />
        {view === "breakdown" && (
          <Select
            label={t("ledger.group")}
            value={group}
            closeOnPick
            align="end"
            options={groups.map((each) => ({ value: each, label: t(GROUP_KEY[each]) }))}
            onChange={(value) => pick({ group: value as UsageGroup })}
          />
        )}
        <Menu {...(initialExportOpen ? { open: true } : {})}>
          <MenuButton className="cst-link" data-menu="team-export" label={t("teamAudit.exportMenu")} disabled={!shown}>
            {t("teamAudit.exportMenu")}
          </MenuButton>
          <MenuPopup side="bottom" align="end" className="acpmux-quick-menu" label={t("teamAudit.exportMenu")}>
            <MenuItem className="acpmux-quick-item" onSelect={csv}>
              {t("teamAudit.export")}
            </MenuItem>
            {save && (
              <MenuItem className="acpmux-quick-item" onSelect={() => void json()}>
                {t("teamAudit.exportJson")}
              </MenuItem>
            )}
          </MenuPopup>
        </Menu>
      </div>
      {view === "overview" && <OverviewView read={main} locale={locale} t={t} />}
      {view === "breakdown" && (
        <Strip
          totals={main.reply?.totals}
          machine={main.reply ? auditHasMachineTime(main.reply) : false}
          locale={locale}
          t={t}
        />
      )}
      <div className="cst-table-note">
        {main.reply?.scope === "self" && <span>{t("teamAudit.self")}</span>}
        {privacyNote && <span className="tma-privacy">{privacyNote}</span>}
        <span className="cst-fill" />
        {notice && (
          <output className="cst-copied tma-saved" data-tone={notice.tone}>
            {notice.text}
          </output>
        )}
      </div>
      {view === "breakdown" && (
        <Breakdown read={main} drill={drill} group={group} locale={locale} t={t} onDrill={drillInto} onBack={backTo} />
      )}
      {view === "efficiency" && <EfficiencyView projects={main} people={people} locale={locale} t={t} />}
    </div>
  );
}

function Breakdown({
  read,
  drill,
  group,
  locale,
  t,
  onDrill,
  onBack,
}: {
  read: AuditRead;
  drill: readonly UsageDrillStep[];
  group: UsageGroup;
  locale: string;
  t: Translate;
  onDrill?: ((row: TeamAuditRow) => void) | undefined;
  onBack: (index: number) => void;
}) {
  const reply = read.reply;
  // The rows on screen are labelled by the grouping they were read for, not the one being read.
  const shown = reply?.groupBy ?? group;
  const rows = reply && auditHasRows(reply) ? reply.rows : [];
  const columns = reply ? breakdownColumns(reply) : { machine: false, prs: false, ci: false, vm: false };
  const status = readStatus(read, t);
  return (
    <div className="cst-scroll tma-scroll">
      {drill.length > 0 && (
        <nav className="tma-drill" aria-label={t("teamAudit.drill")}>
          <button type="button" className="tma-crumb" onClick={() => onBack(0)}>
            {t("teamAudit.drill.all")}
          </button>
          {drill.map((step, index) => (
            <span key={`${step.group}:${step.key}`} className="tma-crumb-wrap">
              <span className="tma-crumb-sep" aria-hidden>
                ›
              </span>
              {index === drill.length - 1 ? (
                <span className="tma-crumb" aria-current="location">
                  {step.label ?? step.key}
                </span>
              ) : (
                <button type="button" className="tma-crumb" onClick={() => onBack(index + 1)}>
                  {step.label ?? step.key}
                </button>
              )}
            </span>
          ))}
        </nav>
      )}
      {rows.length > 0 && (
        <table className="tma-table">
          <thead>
            <tr>
              <th scope="col" className="tma-key">
                <span className="tma-key-text">{t(GROUP_KEY[shown])}</span>
              </th>
              <th scope="col">{t("ledger.total.tokensIn")}</th>
              <th scope="col">{t("ledger.total.tokensOut")}</th>
              <th scope="col">{t("teamAudit.total.cacheRead")}</th>
              <th scope="col">{t("teamAudit.total.cacheWrite")}</th>
              <th scope="col">{t("teamAudit.total.hitRate")}</th>
              <th scope="col">{t("ledger.total.turns")}</th>
              <th scope="col">{t("ledger.total.time")}</th>
              {columns.prs && <th scope="col">{t("teamAudit.total.prs")}</th>}
              {columns.ci && <th scope="col">{t("teamAudit.total.ciTime")}</th>}
              {columns.vm && <th scope="col">{t("teamAudit.total.vmTime")}</th>}
              {columns.machine && <th scope="col">{t("teamAudit.total.machineTime")}</th>}
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => {
              const name = rowName(shown, row, locale, t);
              const folded = row.key === USAGE_OTHERS_KEY;
              const drillable = onDrill && !folded && row.key !== TEAM_AUDIT_NONE;
              return (
                <tr key={`${shown}:${row.key}`} data-others={folded || undefined}>
                  <th scope="row" className="tma-key">
                    {drillable ? (
                      <button type="button" className="tma-key-text tma-drill-row" onClick={() => onDrill(row)}>
                        {name}
                      </button>
                    ) : (
                      <span className="tma-key-text">
                        {name}
                        {folded && row.foldedPeople !== undefined && (
                          <span className="tma-folded">
                            {" · "}
                            {t("teamAudit.others.people", { count: formatCount(row.foldedPeople, locale) })}
                          </span>
                        )}
                      </span>
                    )}
                  </th>
                  <Measures totals={row} columns={columns} locale={locale} />
                </tr>
              );
            })}
          </tbody>
        </table>
      )}
      <div className="cst-status" aria-live="polite">
        {status}
      </div>
    </div>
  );
}

type Columns = { machine: boolean; prs: boolean; ci: boolean; vm: boolean };

/// The export's columns show only where the answer carries them: an audit answer keeps its table.
function breakdownColumns(reply: TeamAuditReply): Columns {
  const has = (field: "prsLanded" | "ciMinutes" | "vmVcpuSeconds") =>
    reply.totals[field] !== undefined || reply.rows.some((row) => row[field] !== undefined);
  return { machine: auditHasMachineTime(reply), prs: has("prsLanded"), ci: has("ciMinutes"), vm: has("vmVcpuSeconds") };
}

const MINUTE = 60_000;
const dash = (value: number | undefined, render: (value: number) => string) =>
  value === undefined ? "–" : render(value);

function Measures({ totals, columns, locale }: { totals: TeamAuditTotals; columns: Columns; locale: string }) {
  return (
    <>
      <td>{formatCount(auditTokensIn(totals), locale)}</td>
      <td>{formatCount(totals.outputTokens, locale)}</td>
      <td>{formatCount(totals.cacheReadTokens, locale)}</td>
      <td>{formatCount(totals.cacheWriteTokens, locale)}</td>
      <td>{formatHitRate(totals.cacheHitRate, locale)}</td>
      <td>{formatCount(totals.turns, locale)}</td>
      <td>{formatDuration(agentMs(totals), locale)}</td>
      {columns.prs && <td>{dash(totals.prsLanded, (value) => formatCount(value, locale))}</td>}
      {columns.ci && <td>{dash(totals.ciMinutes, (value) => formatDuration(value * MINUTE, locale))}</td>}
      {columns.vm && <td>{dash(totals.vmVcpuSeconds, (value) => formatDuration(value * 1000, locale))}</td>}
      {columns.machine && <td>{dash(totals.machineMs, (value) => formatDuration(value, locale))}</td>}
    </>
  );
}

function Strip({
  totals,
  machine,
  locale,
  t,
}: {
  totals?: TeamAuditTotals;
  machine: boolean;
  locale: string;
  t: Translate;
}) {
  // The tiles hold their place before the first answer: dashes, never a strip that pops in.
  const value = (render: (totals: TeamAuditTotals) => string) => (totals ? render(totals) : "–");
  const tiles: [string, string][] = [
    [t("ledger.total.time"), value((each) => formatDuration(agentMs(each), locale))],
    ...(machine
      ? ([[t("teamAudit.total.machineTime"), value((each) => formatDuration(each.machineMs ?? 0, locale))]] as [
          string,
          string,
        ][])
      : []),
    ...(totals?.prsLanded !== undefined
      ? ([[t("teamAudit.total.prs"), formatCount(totals.prsLanded, locale)]] as [string, string][])
      : []),
    [t("ledger.total.tokensIn"), value((each) => formatCount(auditTokensIn(each), locale))],
    [t("teamAudit.total.cacheRead"), value((each) => formatCount(each.cacheReadTokens, locale))],
    [t("teamAudit.total.hitRate"), value((each) => formatHitRate(each.cacheHitRate, locale))],
    [t("ledger.total.turns"), value((each) => formatCount(each.turns, locale))],
  ];
  return (
    <dl className="cst-strip">
      {tiles.map(([label, shown]) => (
        <div key={label} className="cst-tile">
          <dt>{label}</dt>
          <dd>{shown}</dd>
        </div>
      ))}
    </dl>
  );
}
