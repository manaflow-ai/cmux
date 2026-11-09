// Costs (ledger/LedgerScreen.tsx): what agents spent on this machine, from acpmux's `_acpmux/ledger`
// (an index folded at each turn, so a read never scans a log). One totals strip, a range, a
// group-by, and rows ranked by cost with a bar each. Every cost says where it came from: the agent
// reported it, it was priced from acpmux's price table (whose version the page shows), or no price
// was known for the model. Beside the cost: what cache reads saved and how much of the input they
// were, and a CSV of the rows shown, for an audit or a spreadsheet.

export const LEDGER_METHOD = "_acpmux/ledger";

export const LEDGER_RANGES = ["24h", "7d", "30d", "all"] as const;
export type LedgerRange = (typeof LEDGER_RANGES)[number];

/// What rows group by: a session each, or one of acpmux's rollups.
/// `account`: the sign-in a chat ran on (its Claude profile or preset), so spend on an API key and
/// on a subscription read apart.
export const LEDGER_GROUPS = [
  "session",
  "workspace",
  "repo",
  "pr",
  "day",
  "person",
  "vendor",
  "model",
  "account",
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

export type LedgerTotals = {
  costUsd: number;
  harnessCostUsd: number;
  tableCostUsd: number;
  unpricedTurns: number;
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheWriteTokens: number;
  /// Of `cacheWriteTokens`, the hour-long writes (priced at their own tier); 0 from an older acpmux.
  cacheWrite1hTokens: number;
  /// What cache reads saved against the input price, at acpmux's price table.
  cacheSavedUsd: number;
  turns: number;
  toolCalls: number;
  wallMs: number;
  sessions: number;
};

/// Tokens in: what the agent sent that was not a cache read (uncached input plus cache writes).
/// Cache reads are the same context sent again; counted in, a long chat's input reads as many
/// times what it is.
export const tokensIn = (totals: LedgerTotals) => totals.inputTokens + totals.cacheWriteTokens;

/// The share of all input, 0 to 1, that was read from cache; undefined with no input at all.
export function cacheShare(totals: LedgerTotals): number | undefined {
  const all = totals.inputTokens + totals.cacheReadTokens + totals.cacheWriteTokens;
  return all > 0 ? totals.cacheReadTokens / all : undefined;
}

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
export function ledgerParams(range: LedgerRange, now: number): Record<string, unknown> {
  const span = RANGE_MS[range];
  // All time starts at 0: acpmux reads a missing `since` as its default window, not as no start.
  return {
    since: span !== undefined ? now - span : 0,
    until: now,
    limit: LEDGER_ROW_LIMIT,
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
    cacheWrite1hTokens: num(body.cacheWrite1hTokens),
    cacheSavedUsd: num(body.cacheSavedUsd),
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

/// The CSV columns after the group and its label, as acpmux names them (`acpmux ledger --csv`).
const CSV_FIELDS = [
  "costUsd",
  "harnessCostUsd",
  "tableCostUsd",
  "unpricedTurns",
  "inputTokens",
  "outputTokens",
  "cacheReadTokens",
  "cacheWriteTokens",
  "cacheWrite1hTokens",
  "cacheSavedUsd",
  "turns",
  "toolCalls",
  "wallMs",
  "sessions",
] as const satisfies readonly (keyof LedgerTotals)[];

/// A CSV field: one line with no tab (a paste splits cells on both, and a split cell would dodge
/// the next rule), never read by a spreadsheet as a formula (a leading `=`, `+`, `-` or `@` gets a
/// `'`), and quoted when it holds a comma or quote.
function csvField(value: string): string {
  const flat = value.replace(/[\t\r\n]/g, " ");
  const safe = /^[=+\-@]/.test(flat) ? `'${flat}` : flat;
  return /[",]/.test(safe) ? `"${safe.replaceAll('"', '""')}"` : safe;
}

/// The rows `group` shows as CSV with a header, in the order they show: a session row adds its
/// harness, repository, branch and models.
export function ledgerCsv(reply: LedgerReply, group: LedgerGroup): string {
  const session = group === "session";
  const head = [group, "label", ...(session ? ["harness", "repo", "branch", "models"] : []), ...CSV_FIELDS];
  const rows = new Map(reply.rows.map((row) => [row.sessionId, row]));
  const lines = ledgerLines(reply, group).map((line) => {
    const row = session ? rows.get(line.key) : undefined;
    const extra = session ? [row?.harness ?? "", row?.repo ?? "", row?.branch ?? "", row?.models.join(" ") ?? ""] : [];
    return [line.key, line.label, ...extra]
      .map(csvField)
      .concat(CSV_FIELDS.map((field) => String(line.totals[field])))
      .join(",");
  });
  return `${[head.join(","), ...lines].join("\n")}\n`;
}
