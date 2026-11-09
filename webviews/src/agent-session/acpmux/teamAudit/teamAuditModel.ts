// Team (History > Team, behind the `team-audit` experiment): the team's agent spend from the turns
// teammates share, summed by cmux-platform (`GET /v1/usage/audit`) and read through this Mac's
// acpmux with its cmux sign-in (`_acpmux/team_audit`). A team admin sees every teammate; anyone
// else their own turns. Counts and times only; a cost is shown as time (agent and machine time).

export const TEAM_AUDIT_METHOD = "_acpmux/team_audit";

/// Whole UTC days ending today: the platform sums by day.
export const TEAM_AUDIT_RANGES = ["7d", "30d", "90d"] as const;
export type TeamAuditRange = (typeof TEAM_AUDIT_RANGES)[number];
const RANGE_DAYS: Record<TeamAuditRange, number> = { "7d": 7, "30d": 30, "90d": 90 };

export const TEAM_AUDIT_GROUPS = ["person", "repo", "model", "harness", "machine", "day"] as const;
export type TeamAuditGroup = (typeof TEAM_AUDIT_GROUPS)[number];

/// The platform's key for turns from a client that does not send the field a grouping reads.
export const TEAM_AUDIT_NONE = "none";

export type TeamAuditTotals = {
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheWriteTokens: number;
  /// Cache reads over all input, 0 to 1; null with no input.
  cacheHitRate: number | null;
  turns: number;
  toolCalls: number;
  wallMs: number;
  sessions: number;
  /// Cloud machine running time, where the platform joins it (person and day rows, the totals).
  machineMs?: number;
};

export type TeamAuditRow = TeamAuditTotals & { key: string; label?: string };

export type TeamAuditReply = {
  scope: "team" | "self";
  range: { since: string; until: string };
  groupBy: TeamAuditGroup;
  totals: TeamAuditTotals;
  rows: TeamAuditRow[];
};

/// What one read answered: the audit, or why there is none.
export type TeamAuditAnswer =
  | { kind: "ready"; reply: TeamAuditReply }
  | { kind: "signedOut" }
  | { kind: "off" }
  | { kind: "notShared" }
  | { kind: "failed"; message?: string };

/// What a CSV download answered.
export type TeamAuditSaved = { kind: "saved"; path: string } | Exclude<TeamAuditAnswer, { kind: "ready" }>;

const DAY_MS = 86_400_000;
const utcDay = (ms: number) => new Date(ms).toISOString().slice(0, 10);

/// The read for `range` ending today (UTC) grouped by `group`; `csv` asks for the file instead.
export function teamAuditParams(
  range: TeamAuditRange,
  group: TeamAuditGroup,
  now: number,
  format: "json" | "csv" = "json",
): Record<string, unknown> {
  return {
    since: utcDay(now - (RANGE_DAYS[range] - 1) * DAY_MS),
    until: utcDay(now),
    groupBy: group,
    format,
  };
}

const record = (value: unknown) =>
  value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : undefined;
const num = (value: unknown) => (typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : 0);
const text = (value: unknown) => (typeof value === "string" && value ? value : undefined);

function readTotals(value: unknown): TeamAuditTotals {
  const body = record(value) ?? {};
  const rate = body.cacheHitRate;
  return {
    inputTokens: num(body.inputTokens),
    outputTokens: num(body.outputTokens),
    cacheReadTokens: num(body.cacheReadTokens),
    cacheWriteTokens: num(body.cacheWriteTokens),
    cacheHitRate: typeof rate === "number" && Number.isFinite(rate) && rate >= 0 && rate <= 1 ? rate : null,
    turns: num(body.turns),
    toolCalls: num(body.toolCalls),
    wallMs: num(body.wallMs),
    sessions: num(body.sessions),
    ...(typeof body.machineMs === "number" && Number.isFinite(body.machineMs) && body.machineMs >= 0
      ? { machineMs: body.machineMs }
      : {}),
  };
}

function readStatus(body: Record<string, unknown>): Exclude<TeamAuditAnswer, { kind: "ready" }> {
  switch (body.status) {
    case "signedOut":
      return { kind: "signedOut" };
    case "off":
      return { kind: "off" };
    case "notShared":
      return { kind: "notShared" };
    default: {
      const message = text(body.message);
      return message ? { kind: "failed", message } : { kind: "failed" };
    }
  }
}

/// acpmux's answer, read defensively: anything but `ok` with an audit is one of the reasons.
export function readTeamAudit(value: unknown): TeamAuditAnswer {
  const body = record(value) ?? {};
  const audit = record(body.audit);
  if (body.status !== "ok" || !audit) return readStatus(body);
  const range = record(audit.range) ?? {};
  const groupBy = TEAM_AUDIT_GROUPS.find((group) => group === audit.groupBy) ?? "person";
  const rows = (Array.isArray(audit.rows) ? audit.rows : []).flatMap((raw): TeamAuditRow[] => {
    const row = record(raw);
    const key = text(row?.key);
    if (!row || !key) return [];
    const label = text(row.label);
    return [{ ...readTotals(row), key, ...(label ? { label } : {}) }];
  });
  return {
    kind: "ready",
    reply: {
      scope: audit.scope === "team" ? "team" : "self",
      range: { since: text(range.since) ?? "", until: text(range.until) ?? "" },
      groupBy,
      totals: readTotals(audit.totals),
      rows,
    },
  };
}

/// A CSV download's answer: the file's path, or why none was written.
export function readTeamAuditSaved(value: unknown): TeamAuditSaved {
  const body = record(value) ?? {};
  const path = text(body.path);
  return body.status === "saved" && path ? { kind: "saved", path } : readStatus(body);
}

/// Tokens in, as History > Costs counts them: uncached input plus cache writes, never cache reads.
export const auditTokensIn = (totals: TeamAuditTotals) => totals.inputTokens + totals.cacheWriteTokens;

/// A hit rate as a whole percent in the page's language; a dash when there was no input.
export function formatHitRate(rate: number | null, locale?: string): string {
  if (rate === null) return "–";
  return new Intl.NumberFormat(locale, { style: "percent", maximumFractionDigits: 0 }).format(rate);
}

/// What a row's key reads as: a day as a date, a machine that is the person's own as its label, the
/// platform's `none` as `none` (localized by the screen), anything else as the key.
export function auditRowLabel(group: TeamAuditGroup, row: TeamAuditRow, locale?: string): string {
  if (group === "day" && /^\d{4}-\d{2}-\d{2}$/.test(row.key)) {
    return new Intl.DateTimeFormat(locale, { month: "short", day: "numeric", weekday: "short", timeZone: "UTC" }).format(
      new Date(`${row.key}T12:00:00Z`),
    );
  }
  return row.label ?? row.key;
}

/// Whether the reply has anything to show: a row with turns or machine time.
export const auditHasRows = (reply: TeamAuditReply) =>
  reply.rows.some((row) => row.turns > 0 || (row.machineMs ?? 0) > 0);

/// Whether any row carries machine time, so the column is shown.
export const auditHasMachineTime = (reply: TeamAuditReply) =>
  reply.totals.machineMs !== undefined || reply.rows.some((row) => row.machineMs !== undefined);
