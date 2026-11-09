// Costs (ledger/LedgerScreen.tsx): what agents spent on this machine, from acpmux's `_acpmux/ledger`
// (an index folded at each turn, so a read never scans a log). One totals strip, a range, a
// group-by, and rows ranked by cost with a bar each. Every cost says where it came from: the agent
// reported it, it was priced from acpmux's price table (whose version the page shows), or no price
// was known for the model. Export writes the same range and grouping as CSV or JSON
// (`ledgerCsv`, `ledgerJson`), every row the read returned.

import { cacheReadShare } from "../usageStats";

export const LEDGER_METHOD = "_acpmux/ledger";

export const LEDGER_RANGES = ["24h", "7d", "30d", "all"] as const;
export type LedgerRange = (typeof LEDGER_RANGES)[number];

/// What rows group by: a session each, or one of acpmux's rollups. There is no machine grouping:
/// this ledger is one machine's (acpmux never forwards `_acpmux/ledger` to a peer), so `person`
/// is this machine's login and name (`user@machine`) and machines group in a team view.
export const LEDGER_GROUPS = [
  "session",
  "workspace",
  "repo",
  "pr",
  "day",
  "person",
  "account",
  "vendor",
  "model",
] as const;
export type LedgerGroup = (typeof LEDGER_GROUPS)[number];
export type LedgerRollupDim = Exclude<LedgerGroup, "session">;

const HOUR_MS = 3_600_000;
const DAY_MS = 24 * HOUR_MS;
const RANGE_MS: Record<LedgerRange, number | undefined> = {
  "24h": DAY_MS,
  "7d": 7 * DAY_MS,
  "30d": 30 * DAY_MS,
  all: undefined,
};

/// How many session rows one read asks for (acpmux's own default).
export const LEDGER_ROW_LIMIT = 200;
/// How many an export asks for: acpmux's most, so a file holds every session of a busy month.
export const LEDGER_EXPORT_LIMIT = 5000;

export type LedgerTotals = {
  costUsd: number;
  harnessCostUsd: number;
  tableCostUsd: number;
  unpricedTurns: number;
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheWriteTokens: number;
  turns: number;
  toolCalls: number;
  wallMs: number;
  sessions: number;
};

/// Tokens in: what the agent sent that was not a cache read (uncached input plus cache writes).
/// Cache reads are the same context sent again; counted in, a long chat's input reads as many
/// times what it is.
export const tokensIn = (totals: LedgerTotals) => totals.inputTokens + totals.cacheWriteTokens;

/// The cache hit rate: of the prompt tokens (uncached input, cache reads and cache writes), the
/// share the prompt cache served; undefined with none. Session Info's prompt cache share is the
/// same number (usageStats.ts `cacheReadShare`).
export const cacheHitRate = (totals: LedgerTotals) =>
  cacheReadShare(totals.cacheReadTokens, totals.inputTokens, totals.cacheWriteTokens);

export type LedgerSession = LedgerTotals & {
  sessionId: string;
  title: string;
  harness?: string;
  vendor?: string;
  models: string[];
  workspaceId?: string;
  repo?: string;
  branch?: string;
  pullRequests: string[];
  person?: string;
  account?: string;
  createdAt?: number;
  lastAt?: number;
};

export type LedgerRollup = LedgerTotals & { key: string; label?: string };

export type LedgerReply = {
  priceTable?: { version: string; currency: string };
  range: { since?: number; until?: number };
  totals: LedgerTotals;
  rows: LedgerSession[];
  rollups: Partial<Record<LedgerRollupDim, LedgerRollup[]>>;
};

/// The read for `range` ending `now`: every rollup the page offers, in one request.
export function ledgerParams(
  range: LedgerRange,
  now: number,
  limit: number = LEDGER_ROW_LIMIT,
): Record<string, unknown> {
  const span = RANGE_MS[range];
  // All time starts at 0: acpmux reads a missing `since` as its default window, not as no start.
  return {
    since: span !== undefined ? now - span : 0,
    until: now,
    limit,
    groupBy: LEDGER_GROUPS.filter((group): group is LedgerRollupDim => group !== "session"),
  };
}

const record = (value: unknown) =>
  value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : undefined;
const num = (value: unknown) => (typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : 0);
const text = (value: unknown) => (typeof value === "string" && value ? value : undefined);

function readTotals(value: unknown): LedgerTotals {
  const body = record(value) ?? {};
  return {
    costUsd: num(body.costUsd),
    harnessCostUsd: num(body.harnessCostUsd),
    tableCostUsd: num(body.tableCostUsd),
    unpricedTurns: num(body.unpricedTurns),
    inputTokens: num(body.inputTokens),
    outputTokens: num(body.outputTokens),
    cacheReadTokens: num(body.cacheReadTokens),
    cacheWriteTokens: num(body.cacheWriteTokens),
    turns: num(body.turns),
    toolCalls: num(body.toolCalls),
    wallMs: num(body.wallMs),
    sessions: num(body.sessions),
  };
}

const strings = (value: unknown) =>
  (Array.isArray(value) ? value : []).filter((each): each is string => typeof each === "string" && each.length > 0);

/// Reads acpmux's answer; a malformed row is dropped, a missing number reads as zero.
export function readLedger(value: unknown): LedgerReply {
  const body = record(value) ?? {};
  const table = record(body.priceTable);
  const range = record(body.range) ?? {};
  const rows = (Array.isArray(body.rows) ? body.rows : []).flatMap((raw): LedgerSession[] => {
    const row = record(raw);
    const sessionId = text(row?.sessionId);
    if (!row || !sessionId) return [];
    const optional = (key: string) => {
      const value = text(row[key]);
      return value ? { [key]: value } : {};
    };
    return [
      {
        ...readTotals(row),
        sessionId,
        title: text(row.title) ?? sessionId,
        models: strings(row.models),
        pullRequests: strings(row.pullRequests),
        ...optional("harness"),
        ...optional("vendor"),
        ...optional("workspaceId"),
        ...optional("repo"),
        ...optional("branch"),
        ...optional("person"),
        ...optional("account"),
        ...(typeof row.createdAt === "number" ? { createdAt: row.createdAt } : {}),
        ...(typeof row.lastAt === "number" ? { lastAt: row.lastAt } : {}),
      },
    ];
  });
  const rollups: LedgerReply["rollups"] = {};
  const rawRollups = record(body.rollups) ?? {};
  for (const dim of LEDGER_GROUPS) {
    if (dim === "session") continue;
    const list = rawRollups[dim];
    if (!Array.isArray(list)) continue;
    rollups[dim] = list.flatMap((raw): LedgerRollup[] => {
      const rollup = record(raw);
      const key = typeof rollup?.key === "string" ? rollup.key : undefined;
      if (!rollup || key === undefined) return [];
      const label = text(rollup.label);
      return [{ ...readTotals(rollup), key, ...(label ? { label } : {}) }];
    });
  }
  return {
    ...(text(table?.version)
      ? { priceTable: { version: text(table?.version)!, currency: text(table?.currency) ?? "USD" } }
      : {}),
    range: {
      ...(typeof range.since === "number" ? { since: range.since } : {}),
      ...(typeof range.until === "number" ? { until: range.until } : {}),
    },
    totals: readTotals(body.totals),
    rows,
    rollups,
  };
}

/// Where a row's cost came from: all reported by the agent, all priced from the table, none
/// priced (no price known for its model), or a mix. `unpriced` alongside a cost says some turns
/// had no price, so the cost is a floor.
export type CostSource = "harness" | "table" | "mixed" | "unpriced" | "none";

export function costSource(
  totals: Pick<LedgerTotals, "harnessCostUsd" | "tableCostUsd" | "unpricedTurns" | "turns">,
): CostSource {
  const reported = totals.harnessCostUsd > 0;
  const priced = totals.tableCostUsd > 0;
  if (reported && priced) return "mixed";
  if (reported) return totals.unpricedTurns > 0 ? "mixed" : "harness";
  if (priced) return totals.unpricedTurns > 0 ? "mixed" : "table";
  return totals.unpricedTurns > 0 ? "unpriced" : "none";
}

/// One drawn row: a session, or one group of a rollup.
export type LedgerLine = {
  key: string;
  label: string;
  /// The line under the label: a session's repo and branch, its models.
  detail?: string;
  totals: LedgerTotals;
  /// This row's cost over the largest row's, 0 to 1: the bar's length.
  share: number;
  source: CostSource;
  /// A session row jumps to its chat.
  sessionId?: string;
};

/// The rows for `group`, most expensive first (ties by turns, then label). A rollup acpmux did not
/// send (an older daemon) is an empty list.
export function ledgerLines(reply: LedgerReply, group: LedgerGroup): LedgerLine[] {
  const lines: LedgerLine[] =
    group === "session"
      ? reply.rows.map((row) => ({
          key: row.sessionId,
          label: row.title,
          ...sessionDetail(row),
          totals: row,
          share: 0,
          source: costSource(row),
          sessionId: row.sessionId,
        }))
      : (reply.rollups[group] ?? []).map((rollup) => ({
          key: rollup.key,
          label: rollup.label ?? rollup.key,
          totals: rollup,
          share: 0,
          source: costSource(rollup),
        }));
  lines.sort(
    (a, b) =>
      b.totals.costUsd - a.totals.costUsd ||
      b.totals.turns - a.totals.turns ||
      (a.label < b.label ? -1 : a.label > b.label ? 1 : 0),
  );
  const top = lines[0]?.totals.costUsd ?? 0;
  for (const line of lines) line.share = top > 0 ? Math.min(1, line.totals.costUsd / top) : 0;
  return lines;
}

function sessionDetail(row: LedgerSession): { detail?: string } {
  const parts = [
    row.repo && row.branch ? `${row.repo} · ${row.branch}` : (row.repo ?? row.branch),
    row.models.join(", "),
  ];
  const detail = parts.filter(Boolean).join(" · ");
  return detail ? { detail } : {};
}

/// Money, in the page's language: cents always, and a positive amount under a cent says so
/// instead of reading as nothing.
export function formatCost(usd: number, locale?: string): string {
  const format = new Intl.NumberFormat(locale, {
    style: "currency",
    currency: "USD",
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  });
  if (usd > 0 && usd < 0.005) return `<${format.format(0.01)}`;
  return format.format(usd);
}

/// A token or call count, short (1.2K, 3.4M).
export function formatCount(n: number, locale?: string): string {
  return new Intl.NumberFormat(locale, { notation: "compact", maximumFractionDigits: 1 }).format(n);
}

/// Agent time as hours and minutes, in the page's language.
export function formatDuration(ms: number, locale?: string): string {
  const minutes = Math.round(ms / 60_000);
  const hours = Math.floor(minutes / 60);
  const unit = (value: number, kind: "hour" | "minute") =>
    new Intl.NumberFormat(locale, { style: "unit", unit: kind, unitDisplay: "narrow" }).format(value);
  if (hours === 0) return unit(minutes, "minute");
  const rest = minutes % 60;
  return rest === 0 ? unit(hours, "hour") : `${unit(hours, "hour")} ${unit(rest, "minute")}`;
}

/// A `day` rollup's key (`YYYY-MM-DD`) as a date in the page's language; any other key as it is.
export function groupLabel(group: LedgerGroup, line: LedgerLine, locale?: string): string {
  if (group !== "day" || !/^\d{4}-\d{2}-\d{2}$/.test(line.key)) return line.label;
  const date = new Date(`${line.key}T12:00:00Z`);
  return new Intl.DateTimeFormat(locale, { month: "short", day: "numeric", weekday: "short", timeZone: "UTC" }).format(
    date,
  );
}

/// What Export writes: CSV for a spreadsheet, JSON for a script.
export type LedgerExportKind = "csv" | "json";

type Cell = string | number | undefined;

/// The columns of an exported row, in order: the CSV header and the JSON row keys.
const EXPORT_COLUMNS = [
  "groupBy",
  "key",
  "label",
  "sessionId",
  "harness",
  "vendor",
  "models",
  "repo",
  "branch",
  "pullRequests",
  "person",
  "account",
  "lastAt",
  "costUsd",
  "costSource",
  "harnessCostUsd",
  "tableCostUsd",
  "unpricedTurns",
  "inputTokens",
  "cacheReadTokens",
  "cacheWriteTokens",
  "cacheHitRate",
  "tokensIn",
  "outputTokens",
  "turns",
  "toolCalls",
  "wallMs",
  "sessions",
  "rangeSince",
  "rangeUntil",
  "priceTableVersion",
] as const;
type ExportColumn = (typeof EXPORT_COLUMNS)[number];

/// Money to a millionth of a dollar: sums of floats never print as 0.30000000000000004.
const money = (usd: number) => Math.round(usd * 1e6) / 1e6;
const iso = (ms: number | undefined) => (ms === undefined ? undefined : new Date(ms).toISOString());

function exportNumbers(totals: LedgerTotals): Partial<Record<ExportColumn, Cell>> {
  return {
    costUsd: money(totals.costUsd),
    costSource: costSource(totals),
    harnessCostUsd: money(totals.harnessCostUsd),
    tableCostUsd: money(totals.tableCostUsd),
    unpricedTurns: totals.unpricedTurns,
    inputTokens: totals.inputTokens,
    cacheReadTokens: totals.cacheReadTokens,
    cacheWriteTokens: totals.cacheWriteTokens,
    cacheHitRate: cacheHitRate(totals),
    tokensIn: tokensIn(totals),
    outputTokens: totals.outputTokens,
    turns: totals.turns,
    toolCalls: totals.toolCalls,
    wallMs: totals.wallMs,
    sessions: totals.sessions,
  };
}

/// Every row of `group` the read returned (not only the ones on screen), ranked as the page
/// ranks them, each with the range and the price table it was read with.
function exportRows(reply: LedgerReply, group: LedgerGroup): Partial<Record<ExportColumn, Cell>>[] {
  const context = {
    rangeSince: iso(reply.range.since),
    rangeUntil: iso(reply.range.until),
    priceTableVersion: reply.priceTable?.version,
  };
  return ledgerLines(reply, group).map((line) => {
    // A session line's totals are its whole row (`ledgerLines`).
    const session = line.sessionId ? (line.totals as LedgerSession) : undefined;
    return {
      groupBy: group,
      key: line.key,
      label: line.label,
      ...(session
        ? {
            sessionId: session.sessionId,
            harness: session.harness,
            vendor: session.vendor,
            models: session.models.join(" "),
            repo: session.repo,
            branch: session.branch,
            pullRequests: session.pullRequests.join(" "),
            person: session.person,
            account: session.account,
            lastAt: iso(session.lastAt),
          }
        : {}),
      ...exportNumbers(line.totals),
      ...context,
    };
  });
}

/// One CSV field (RFC 4180): quoted when it holds a comma, a quote or a line break, its quotes
/// doubled. Text a spreadsheet would run as a formula (a title starting with =, +, - or @) gets a
/// leading apostrophe, so a chat's title can never become a formula in someone's sheet.
export function csvField(value: Cell): string {
  if (value === undefined) return "";
  if (typeof value === "number") return String(value);
  const text = /^[=+\-@\t\r]/.test(value) ? `'${value}` : value;
  return /[",\r\n]/.test(text) ? `"${text.replaceAll('"', '""')}"` : text;
}

/// The range and grouping as CSV: a header, then one line per row, CRLF line ends.
export function ledgerCsv(reply: LedgerReply, group: LedgerGroup): string {
  const lines = [EXPORT_COLUMNS.join(",")];
  for (const row of exportRows(reply, group)) {
    lines.push(EXPORT_COLUMNS.map((column) => csvField(row[column])).join(","));
  }
  return `${lines.join("\r\n")}\r\n`;
}

/// The range and grouping as JSON: the range, the price table, the totals and every row.
export function ledgerJson(reply: LedgerReply, range: LedgerRange, group: LedgerGroup): string {
  const rows = exportRows(reply, group).map((row) =>
    Object.fromEntries(
      EXPORT_COLUMNS.flatMap((column): [ExportColumn, Cell][] =>
        row[column] === undefined ? [] : [[column, row[column]]],
      ),
    ),
  );
  const body = {
    range: { name: range, since: iso(reply.range.since), until: iso(reply.range.until) },
    groupBy: group,
    ...(reply.priceTable ? { priceTable: reply.priceTable } : {}),
    totals: exportNumbers(reply.totals),
    rows,
  };
  return `${JSON.stringify(body, null, 2)}\n`;
}

/// The file's name without its extension: `cmux-costs-7d-by-repo-2026-11-09` (the range's end day, UTC).
export function ledgerFileName(reply: LedgerReply, range: LedgerRange, group: LedgerGroup): string {
  const day = reply.range.until !== undefined ? new Date(reply.range.until).toISOString().slice(0, 10) : undefined;
  return ["cmux-costs", range, "by", group, day].filter(Boolean).join("-");
}
