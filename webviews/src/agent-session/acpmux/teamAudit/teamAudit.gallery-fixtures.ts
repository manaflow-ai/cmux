// l10n-allow-file: gallery fixtures, public-safe sample people, teams, projects and models.
// The usage export's answers for Team's gallery (TeamAuditScreen.gallery.tsx): a 12-person team in
// three teams, over four projects and three models, 30 days ending 2026-11-09. Every row is summed
// here from per-person, per-day, per-project, per-model cells, as the platform would answer, so any
// grouping and any drill-down slice agree with the totals. Gallery data only: the app's numbers are
// the platform's (usageExport.ts).
import type { UsagePrivacy } from "./usageExport";

type Person = {
  key: string;
  label: string;
  team: string;
  scale: number;
  prsPerUnit: number;
  shares: "person" | "team";
};

const TEAMS: Record<string, string> = { platform: "Platform", apps: "Apps", infra: "Infra" };
const PEOPLE: Person[] = [
  { key: "ada", label: "Ada", team: "platform", scale: 1.6, prsPerUnit: 1.2, shares: "person" },
  { key: "grace", label: "Grace", team: "platform", scale: 1.3, prsPerUnit: 1.1, shares: "person" },
  { key: "linus", label: "Linus", team: "platform", scale: 1.4, prsPerUnit: 0.35, shares: "person" },
  { key: "margaret", label: "Margaret", team: "platform", scale: 0.9, prsPerUnit: 1.0, shares: "person" },
  { key: "alan", label: "Alan", team: "platform", scale: 0.7, prsPerUnit: 0.9, shares: "person" },
  { key: "barbara", label: "Barbara", team: "apps", scale: 1.2, prsPerUnit: 1.3, shares: "person" },
  { key: "dennis", label: "Dennis", team: "apps", scale: 1.0, prsPerUnit: 0.95, shares: "person" },
  { key: "frances", label: "Frances", team: "apps", scale: 0.8, prsPerUnit: 1.05, shares: "person" },
  { key: "ken", label: "Ken", team: "apps", scale: 0.6, prsPerUnit: 0.3, shares: "person" },
  { key: "radia", label: "Radia", team: "infra", scale: 1.1, prsPerUnit: 0.8, shares: "team" },
  { key: "edsger", label: "Edsger", team: "infra", scale: 0.9, prsPerUnit: 0.7, shares: "team" },
  { key: "hedy", label: "Hedy", team: "infra", scale: 0.5, prsPerUnit: 0.9, shares: "team" },
];
/// Where each team's work lands: project weights per team.
const PROJECTS: Record<string, Record<string, number>> = {
  platform: { cmux: 0.6, "cmux-platform": 0.3, web: 0.1 },
  apps: { cmux: 0.3, web: 0.7 },
  infra: { infra: 0.7, "cmux-platform": 0.3 },
};
const MODELS: Record<string, { weight: number; harness: string; label: string }> = {
  "claude-opus": { weight: 0.5, harness: "claude", label: "Claude Opus" },
  "claude-sonnet": { weight: 0.2, harness: "claude", label: "Claude Sonnet" },
  codex: { weight: 0.3, harness: "codex", label: "Codex" },
};
const HARNESSES: Record<string, string> = { claude: "Claude Code", codex: "Codex" };
const DAYS = Array.from({ length: 30 }, (_, i) => new Date(Date.UTC(2026, 9, 11 + i)).toISOString().slice(0, 10));

type Cell = {
  team: string;
  project: string;
  person: string;
  model: string;
  harness: string;
  machine: string;
  day: string;
  session: string;
  units: number;
  prs: number;
};

/// A day's weight: weekdays full, weekends light, a slow climb over the month and a release spike.
function dayWeight(day: string, index: number): number {
  const weekday = new Date(`${day}T12:00:00Z`).getUTCDay();
  const weekend = weekday === 0 || weekday === 6 ? 0.25 : 1;
  const spike = index === 22 ? 1.6 : 1;
  const wobble = 0.85 + 0.3 * Math.abs(Math.sin(index * 1.7));
  return weekend * spike * wobble * (0.8 + index / 75);
}

const CELLS: Cell[] = PEOPLE.flatMap((person) =>
  DAYS.flatMap((day, index) =>
    Object.entries(PROJECTS[person.team]!).flatMap(([project, share]) =>
      Object.entries(MODELS).map(([model, { weight, harness }]) => {
        const units = person.scale * dayWeight(day, index) * share * weight;
        return {
          team: person.team,
          project,
          person: person.key,
          model,
          harness,
          machine: `${person.key}-mbp`,
          day,
          session: `${person.key}-${day}-${project}`,
          units,
          prs: units * person.prsPerUnit * 0.9,
        };
      }),
    ),
  ),
);

type Sum = { units: number; prs: number; sessions: Set<string> };

/// A row's measures from its summed units: tokens, turns, time and the export's fields.
function measures({ units, prs, sessions }: Sum, folded?: number) {
  const input = Math.round(units * 210_000);
  const cacheRead = Math.round(units * 1_900_000);
  const cacheWrite = Math.round(units * 160_000);
  const agentMinutes = Math.round(units * 95);
  const prsLanded = Math.round(prs);
  return {
    inputTokens: input,
    outputTokens: Math.round(units * 48_000),
    cacheReadTokens: cacheRead,
    cacheWriteTokens: cacheWrite,
    cacheHitRate: input + cacheRead + cacheWrite > 0 ? cacheRead / (input + cacheRead + cacheWrite) : null,
    turns: Math.round(units * 60),
    toolCalls: Math.round(units * 410),
    wallMs: agentMinutes * 60_000,
    sessions: sessions.size,
    agentMinutes,
    ciMinutes: Math.round(prs * 14),
    prsLanded,
    vmVcpuSeconds: Math.round(units * 4 * 3600),
    vmGibSeconds: Math.round(units * 16 * 3600),
    costAsTimeMinutes: Math.round(units * 22),
    ...(folded !== undefined ? { foldedPeople: folded } : {}),
  };
}

const LABELS: Record<string, (key: string) => string | undefined> = {
  team: (key) => TEAMS[key],
  person: (key) => PEOPLE.find((person) => person.key === key)?.label,
  model: (key) => MODELS[key]?.label,
  harness: (key) => HARNESSES[key],
};

/// The fixture's answers at one privacy level: `person` folds the people who share at team level
/// into Others; `team` folds everyone.
export function usageFixture({ privacy }: { privacy: UsagePrivacy }) {
  const folds = (person: string) =>
    privacy !== "person" && privacy !== "session"
      ? true
      : PEOPLE.find((each) => each.key === person)?.shares === "team";
  const rowsFor = (groupBy: string, where: Record<string, string>) => {
    const cells = CELLS.filter((cell) =>
      Object.entries(where).every(([field, value]) => (cell as Record<string, unknown>)[field] === value),
    );
    const personal = groupBy === "person" || groupBy === "machine" || groupBy === "session";
    const groups = new Map<string, Sum & { folded: Set<string> }>();
    for (const cell of cells) {
      const field = groupBy === "repo" ? "project" : groupBy;
      const raw = String((cell as Record<string, unknown>)[field] ?? "none");
      const key = personal && folds(cell.person) ? "others" : raw;
      const sum = groups.get(key) ?? { units: 0, prs: 0, sessions: new Set(), folded: new Set() };
      sum.units += cell.units;
      sum.prs += cell.prs;
      sum.sessions.add(cell.session);
      if (key === "others") sum.folded.add(cell.person);
      groups.set(key, sum);
    }
    const all = { units: 0, prs: 0, sessions: new Set<string>() };
    for (const cell of cells) {
      all.units += cell.units;
      all.prs += cell.prs;
      all.sessions.add(cell.session);
    }
    const rows = [...groups.entries()]
      .map(([key, sum]) => {
        const label = LABELS[groupBy]?.(key);
        return {
          key,
          ...(label ? { label } : {}),
          ...measures(sum, key === "others" ? sum.folded.size : undefined),
        };
      })
      // The platform's order: most agent time first, Others last; days in day order.
      .sort((a, b) =>
        groupBy === "day"
          ? a.key.localeCompare(b.key)
          : a.key === "others"
            ? 1
            : b.key === "others"
              ? -1
              : b.agentMinutes - a.agentMinutes,
      );
    const totals = measures(all);
    return { rows, totals: { ...totals, minutesPerPr: totals.prsLanded ? totals.agentMinutes / totals.prsLanded : 0 } };
  };
  return {
    /// `_acpmux/usage_export`'s answer for `params` (usageExport.ts), from the cells.
    answer(params: Record<string, unknown>) {
      const groupBy = String(params.groupBy ?? "person");
      if (params.format === "csv") {
        return { status: "saved", path: `~/Downloads/cmux-usage-2026-10-11-2026-11-09-${groupBy}.csv` };
      }
      const where = (params.where ?? {}) as Record<string, string>;
      const { rows, totals } = rowsFor(groupBy, where);
      return {
        status: "ok",
        audit: {
          team: "team_example",
          scope: "team",
          privacy,
          range: { since: DAYS[0], until: DAYS[DAYS.length - 1] },
          groupBy,
          totals,
          rows,
        },
      };
    },
    /// The audit's own fields of the day rows (no export fields), for an audit-only Overview.
    auditDays() {
      return rowsFor("day", {}).rows.map((row) => ({
        key: row.key,
        inputTokens: row.inputTokens,
        outputTokens: row.outputTokens,
        cacheReadTokens: row.cacheReadTokens,
        cacheWriteTokens: row.cacheWriteTokens,
        cacheHitRate: row.cacheHitRate ?? 0,
        turns: row.turns,
        toolCalls: row.toolCalls,
        wallMs: row.wallMs,
        sessions: row.sessions,
        machineMs: Math.round(row.vmVcpuSeconds * 250),
      }));
    },
  };
}
