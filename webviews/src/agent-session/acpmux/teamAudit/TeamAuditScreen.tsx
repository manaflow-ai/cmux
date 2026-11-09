// Team (History > Team, behind the `team-audit` experiment): the team's agent spend from the turns
// teammates share (teamAuditModel.ts). A range and a group-by, a totals strip, then a table with a
// column per measure: tokens in and out, cache reads and writes, cache hit rate, turns, agent time
// and machine time (where the platform joins it). Download CSV saves the same table to Downloads.
// Built like History > Costs (ledger/LedgerScreen.tsx) and with its formatters; spend reads as time.
import { useCallback, useEffect, useRef, useState } from "react";
import { Select } from "../../../ui/Select";
import { Tabs, TabsList, TabsTrigger } from "../../../ui/Tabs";
import { currentLanguage, useT, type StringKey, type Translate } from "../i18n";
import { formatCount, formatDuration } from "../ledger/ledgerModel";
import { isOlderDaemon } from "../queue/queueModel";
import {
  auditHasMachineTime,
  auditHasRows,
  auditRowLabel,
  auditTokensIn,
  formatHitRate,
  readTeamAudit,
  readTeamAuditSaved,
  TEAM_AUDIT_GROUPS,
  TEAM_AUDIT_NONE,
  TEAM_AUDIT_RANGES,
  teamAuditParams,
  type TeamAuditAnswer,
  type TeamAuditGroup,
  type TeamAuditRange,
  type TeamAuditReply,
  type TeamAuditTotals,
} from "./teamAuditModel";
import "../ledger/ledger.css";
import "./teamAudit.css";

/// `group` is the grouping a reply was read for: the table keeps its heading and labels while the
/// next grouping's read runs.
type State =
  | { phase: "loading"; reply?: TeamAuditReply; group?: TeamAuditGroup }
  | { phase: "answered"; answer: TeamAuditAnswer; group: TeamAuditGroup }
  | { phase: "older" };

type Props = {
  /// `_acpmux/team_audit` with `params` (direct.ts `teamAudit`).
  load(params: Record<string, unknown>): Promise<unknown>;
  initialRange?: TeamAuditRange;
  initialGroup?: TeamAuditGroup;
  now?: number;
};

const RANGE_KEY: Record<TeamAuditRange, StringKey> = {
  "7d": "ledger.range.7d",
  "30d": "ledger.range.30d",
  "90d": "teamAudit.range.90d",
};
const GROUP_KEY: Record<TeamAuditGroup, StringKey> = {
  person: "ledger.group.person",
  repo: "ledger.group.repo",
  model: "ledger.group.model",
  harness: "teamAudit.group.harness",
  machine: "teamAudit.group.machine",
  day: "ledger.group.day",
};
const REASON_KEY: Record<Exclude<TeamAuditAnswer["kind"], "ready">, StringKey> = {
  signedOut: "teamAudit.signedOut",
  off: "teamAudit.off",
  notShared: "teamAudit.notShared",
  failed: "teamAudit.failed",
};

export function TeamAuditScreen({ load, initialRange = "30d", initialGroup = "person", now }: Props) {
  const t = useT();
  const locale = currentLanguage();
  const [range, setRange] = useState<TeamAuditRange>(initialRange);
  const [group, setGroup] = useState<TeamAuditGroup>(initialGroup);
  const [state, setState] = useState<State>({ phase: "loading" });
  const [saved, setSaved] = useState<string | undefined>();
  const request = useRef(0);
  const loadRef = useRef(load);
  loadRef.current = load;

  const read = useCallback(
    (which: TeamAuditRange, by: TeamAuditGroup) => {
      const id = ++request.current;
      // The last table stays on screen while the next read runs.
      setState((previous) =>
        previous.phase === "answered" && previous.answer.kind === "ready"
          ? { phase: "loading", reply: previous.answer.reply, group: previous.group }
          : { phase: "loading" },
      );
      loadRef.current(teamAuditParams(which, by, now ?? Date.now())).then(
        (value) => {
          if (id === request.current) setState({ phase: "answered", answer: readTeamAudit(value), group: by });
        },
        (error: unknown) => {
          if (id !== request.current) return;
          setState(isOlderDaemon(error) ? { phase: "older" } : { phase: "answered", answer: { kind: "failed" }, group: by });
        },
      );
    },
    [now],
  );

  useEffect(() => {
    read(range, group);
    const requests = request;
    return () => {
      // A reply after the page left is dropped.
      requests.current++;
    };
  }, [range, group, read]);

  const download = () => {
    setSaved(undefined);
    loadRef.current(teamAuditParams(range, group, now ?? Date.now(), "csv")).then(
      (value) => {
        const answer = readTeamAuditSaved(value);
        setSaved(answer.kind === "saved" ? t("teamAudit.saved", { path: answer.path }) : t(REASON_KEY[answer.kind]));
      },
      () => setSaved(t("teamAudit.failed")),
    );
  };

  const reply =
    state.phase === "answered" && state.answer.kind === "ready"
      ? state.answer.reply
      : state.phase === "loading"
        ? state.reply
        : undefined;
  const status =
    state.phase === "older"
      ? t("teamAudit.older")
      : state.phase === "answered" && state.answer.kind !== "ready"
        ? t(REASON_KEY[state.answer.kind])
        : !reply
          ? t("ledger.loading")
          : !auditHasRows(reply)
            ? t("teamAudit.empty")
            : "";
  // The rows on screen are labelled by the grouping they were read for, not the one being read.
  const shown = (state.phase === "older" ? undefined : state.group) ?? group;
  const machine = reply ? auditHasMachineTime(reply) : false;
  const rows = reply && auditHasRows(reply) ? reply.rows : [];

  return (
    <div className="cst tma" data-loading={state.phase === "loading" || undefined}>
      <div className="cst-controls">
        <Tabs variant="segmented" value={range} onValueChange={(value) => setRange(value as TeamAuditRange)}>
          <TabsList aria-label={t("ledger.range")}>
            {TEAM_AUDIT_RANGES.map((each) => (
              <TabsTrigger key={each} value={each}>
                {t(RANGE_KEY[each])}
              </TabsTrigger>
            ))}
          </TabsList>
        </Tabs>
        <span className="cst-fill" />
        <Select
          label={t("ledger.group")}
          value={group}
          closeOnPick
          align="end"
          options={TEAM_AUDIT_GROUPS.map((each) => ({ value: each, label: t(GROUP_KEY[each]) }))}
          onChange={(value) => setGroup(value as TeamAuditGroup)}
        />
        <button type="button" className="cst-link" disabled={!reply} onClick={download}>
          {t("teamAudit.export")}
        </button>
      </div>
      <Strip totals={reply?.totals} machine={machine} locale={locale} t={t} />
      <div className="cst-table-note">
        {reply?.scope === "self" && <span>{t("teamAudit.self")}</span>}
        <span className="cst-fill" />
        {saved && <span className="tma-saved">{saved}</span>}
      </div>
      <div className="cst-scroll tma-scroll">
        {rows.length > 0 && (
          <table className="tma-table">
            <thead>
              <tr>
                <th scope="col" className="tma-key">
                  {t(GROUP_KEY[shown])}
                </th>
                <th scope="col">{t("ledger.total.tokensIn")}</th>
                <th scope="col">{t("ledger.total.tokensOut")}</th>
                <th scope="col">{t("teamAudit.total.cacheRead")}</th>
                <th scope="col">{t("teamAudit.total.cacheWrite")}</th>
                <th scope="col">{t("teamAudit.total.hitRate")}</th>
                <th scope="col">{t("ledger.total.turns")}</th>
                <th scope="col">{t("ledger.total.time")}</th>
                {machine && <th scope="col">{t("teamAudit.total.machineTime")}</th>}
              </tr>
            </thead>
            <tbody>
              {rows.map((row) => (
                <tr key={`${shown}:${row.key}`}>
                  <th scope="row" className="tma-key" title={row.key}>
                    {row.key === TEAM_AUDIT_NONE ? t("teamAudit.none") : auditRowLabel(shown, row, locale)}
                  </th>
                  <Measures totals={row} machine={machine} locale={locale} />
                </tr>
              ))}
            </tbody>
          </table>
        )}
        <div className="cst-status" aria-live="polite">
          {status}
          {state.phase === "answered" && state.answer.kind === "failed" && (
            <button type="button" className="cst-link" onClick={() => read(range, group)}>
              {t("ledger.retry")}
            </button>
          )}
        </div>
      </div>
    </div>
  );
}

function Measures({ totals, machine, locale }: { totals: TeamAuditTotals; machine: boolean; locale: string }) {
  return (
    <>
      <td>{formatCount(auditTokensIn(totals), locale)}</td>
      <td>{formatCount(totals.outputTokens, locale)}</td>
      <td>{formatCount(totals.cacheReadTokens, locale)}</td>
      <td>{formatCount(totals.cacheWriteTokens, locale)}</td>
      <td>{formatHitRate(totals.cacheHitRate, locale)}</td>
      <td>{formatCount(totals.turns, locale)}</td>
      <td>{formatDuration(totals.wallMs, locale)}</td>
      {machine && <td>{totals.machineMs === undefined ? "–" : formatDuration(totals.machineMs, locale)}</td>}
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
    [t("ledger.total.time"), value((each) => formatDuration(each.wallMs, locale))],
    ...(machine
      ? ([[t("teamAudit.total.machineTime"), value((each) => formatDuration(each.machineMs ?? 0, locale))]] as [
          string,
          string,
        ][])
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
