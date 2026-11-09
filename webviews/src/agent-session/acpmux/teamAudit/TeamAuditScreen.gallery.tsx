// l10n-allow-file: gallery fixtures, public-safe sample people, repositories and models.
// Team (History > Team, TeamAuditScreen.tsx, behind the `team-audit` experiment): a team admin's
// month of shared agent turns, and the states a person can meet: their own turns only, nothing in
// range, not in a sharing team, the audit off, signed out, a failed read, and an older acpmux.
import type { ComponentProps } from "react";
import { componentEntry } from "../../../gallery/format";
import type { TeamAuditScreen } from "./TeamAuditScreen";

type Props = ComponentProps<typeof TeamAuditScreen>;

const HOUR = 3_600_000;
const NOW = Date.UTC(2026, 10, 9, 15);

const row = (key: string, scale: number, extra: Record<string, unknown> = {}) => {
  const input = Math.round(scale * 210_000);
  const cacheRead = Math.round(scale * 1_900_000);
  const cacheWrite = Math.round(scale * 160_000);
  return {
    key,
    inputTokens: input,
    outputTokens: Math.round(scale * 48_000),
    cacheReadTokens: cacheRead,
    cacheWriteTokens: cacheWrite,
    cacheHitRate: cacheRead / (input + cacheRead + cacheWrite),
    turns: Math.round(scale * 60),
    toolCalls: Math.round(scale * 410),
    wallMs: Math.round(scale * 2.5 * HOUR),
    sessions: Math.max(1, Math.round(scale * 4)),
    ...extra,
  };
};

const people = [
  row("ada", 9.4, { machineMs: 14 * HOUR }),
  row("grace", 6.1, { machineMs: 6.5 * HOUR }),
  row("linus", 3.3, { machineMs: 0 }),
  row("margaret", 0.8, { machineMs: 2 * HOUR }),
];
const sum = (rows: ReturnType<typeof row>[]) => {
  const total = rows.reduce(
    (acc, each) => ({
      inputTokens: acc.inputTokens + each.inputTokens,
      outputTokens: acc.outputTokens + each.outputTokens,
      cacheReadTokens: acc.cacheReadTokens + each.cacheReadTokens,
      cacheWriteTokens: acc.cacheWriteTokens + each.cacheWriteTokens,
      turns: acc.turns + each.turns,
      toolCalls: acc.toolCalls + each.toolCalls,
      wallMs: acc.wallMs + each.wallMs,
      sessions: acc.sessions + each.sessions,
      machineMs: acc.machineMs + ((each as { machineMs?: number }).machineMs ?? 0),
    }),
    {
      inputTokens: 0,
      outputTokens: 0,
      cacheReadTokens: 0,
      cacheWriteTokens: 0,
      turns: 0,
      toolCalls: 0,
      wallMs: 0,
      sessions: 0,
      machineMs: 0,
    },
  );
  return {
    ...total,
    cacheHitRate: total.cacheReadTokens / (total.inputTokens + total.cacheReadTokens + total.cacheWriteTokens),
  };
};

const audit = (groupBy: string, rows: ReturnType<typeof row>[], scope = "team") => ({
  status: "ok",
  audit: {
    team: "team_example",
    scope,
    range: { since: "2026-10-11", until: "2026-11-09" },
    groupBy,
    totals: sum(rows),
    rows,
  },
});

const byModel = [
  row("model-large", 12.2),
  row("model-code", 5.4),
  { ...row("none", 1.2), cacheReadTokens: 0, cacheWriteTokens: 0, cacheHitRate: 0 },
];

/// Answers each read for its grouping, so the group-by works in the gallery.
const team: Props["load"] = async (params) =>
  params.format === "csv"
    ? { status: "saved", path: "~/Downloads/cmux-agent-spend-2026-10-11-2026-11-09-person.csv" }
    : params.groupBy === "model"
      ? audit("model", byModel)
      : audit(String(params.groupBy ?? "person"), people);

const base: Props = { load: team, now: NOW };

export default componentEntry<Props>({
  id: "agent-pane.team-audit",
  title: "Team spend",
  area: "Agent pane",
  experimental: true,
  covers: ["agent-session/acpmux/teamAudit/TeamAuditScreen.tsx#TeamAuditScreen"],
  styles: () =>
    Promise.all([import("../styles.css"), import("../ledger/ledger.css"), import("./teamAudit.css")]),
  load: () => import("./TeamAuditScreen").then((module) => module.TeamAuditScreen),
  widths: { narrow: 380, normal: 720, wide: 960 },
  height: 520,
  anchors: [{ selector: ".tma" }],
  variants: {
    loaded: {
      note: "A team admin's month: one row per teammate, with cache reads, hit rate, agent time and machine time.",
      props: base,
    },
    "by-model": {
      note: "Grouped by model; turns from an agent that names none read as Not reported. No machine time column.",
      props: { ...base, initialGroup: "model" },
    },
    "not-admin": {
      note: "A teammate who is not an admin sees only their own turns, and the note says so.",
      props: { ...base, load: async () => audit("person", [people[1]!], "self") },
    },
    empty: {
      note: "Sharing is on, but no turns were shared in the range.",
      props: { ...base, load: async () => audit("person", []) },
    },
    "not-shared": {
      note: "The person is not in a team that shares usage.",
      props: { ...base, load: async () => ({ status: "notShared" }) },
    },
    off: {
      note: "The platform's audit is not on for this team yet.",
      props: { ...base, load: async () => ({ status: "off" }) },
    },
    "signed-out": {
      note: "No cmux sign-in on this Mac.",
      props: { ...base, load: async () => ({ status: "signedOut" }) },
    },
    error: {
      note: "The read failed: the status says so and offers Try again.",
      props: { ...base, load: async () => ({ status: "failed", message: "cmux-platform refused (503)" }) },
    },
    older: {
      note: "This Mac's acpmux predates the team audit: it says so instead of failing.",
      props: { ...base, load: async () => Promise.reject({ code: -32601, message: "Method not found" }) },
    },
    loading: {
      note: "The first read is on its way: the strip holds its place with dashes.",
      props: { ...base, load: () => new Promise(() => {}) },
    },
  },
});
