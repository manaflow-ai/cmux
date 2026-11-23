// The eng-leader usage telemetry types, in one file: cmux-platform's coming `GET /v1/usage/export`
// (team, project, person, model, harness, machine, day or session rows with PRs landed, CI minutes and
// VM time), modelled as optional extensions of today's `GET /v1/usage/audit` row (teamAuditModel.ts)
// so an audit answer renders unchanged. Field names follow the platform's export as drafted; when
// they move, they move here. acpmux sums nothing new for this view: every number below comes from
// the platform, and the page only formats and orders it.
import type { TeamAuditGroup, TeamAuditTotals } from "./teamAuditModel";

/// STUB: the acpmux method that will proxy `GET /v1/usage/export` (cmux-tui/crates/acpmux/src/
/// server/chats/team_audit.rs proxies the audit today). Not in acpmux yet: until it is, History >
/// Team reads `_acpmux/team_audit` only and the views that need export fields (PRs, CI minutes, VM
/// time, team and project rows, drill-down) stay hidden. The gallery answers it from fixtures.
export const USAGE_EXPORT_METHOD = "_acpmux/usage_export";

/// The export's groupings: the audit's, plus team, project (the audit's repo) and session.
export const USAGE_EXPORT_GROUPS = [
  "team",
  "project",
  "person",
  "model",
  "harness",
  "machine",
  "day",
  "session",
] as const;
export type UsageExportGroup = (typeof USAGE_EXPORT_GROUPS)[number];

/// Any grouping the page can show: an audit's or an export's.
export type UsageGroup = TeamAuditGroup | UsageExportGroup;

/// Breakdown's drill-down: a click on a row reads its slice grouped by the next of these.
export const USAGE_DRILL_ORDER: readonly UsageGroup[] = ["team", "project", "person", "model"];

/// How much a team shares (the platform's privacy level): `off` shares nothing; `org` totals only;
/// `team` per team and project; `person` per person; `session` per session too. People who share
/// below `person` fold into one row keyed `USAGE_OTHERS_KEY`.
export const USAGE_PRIVACY_LEVELS = ["off", "org", "team", "person", "session"] as const;
export type UsagePrivacy = (typeof USAGE_PRIVACY_LEVELS)[number];

/// The row the platform folds privacy-limited people into.
export const USAGE_OTHERS_KEY = "others";

/// The least privacy level a grouping needs to be shown.
export const USAGE_GROUP_PRIVACY: Record<UsageGroup, UsagePrivacy> = {
  team: "team",
  project: "team",
  repo: "team",
  model: "org",
  harness: "org",
  day: "org",
  person: "person",
  machine: "person",
  session: "session",
};

/// Whether `group` can be read at `privacy` (no level: an audit answer, which names none).
export const usageGroupAllowed = (group: UsageGroup, privacy?: UsagePrivacy) =>
  !privacy || USAGE_PRIVACY_LEVELS.indexOf(privacy) >= USAGE_PRIVACY_LEVELS.indexOf(USAGE_GROUP_PRIVACY[group]);

/// The export's measures beyond the audit's: each optional, so an audit row is an export row.
export type UsageExportMeasures = {
  /// Agent running time in minutes (the audit's `wallMs`, as the export counts it).
  agentMinutes?: number;
  /// CI runner minutes of the pull requests these turns opened.
  ciMinutes?: number;
  /// Pull requests landed from these turns.
  prsLanded?: number;
  /// Cloud VM time as vCPU-seconds and GiB-seconds.
  vmVcpuSeconds?: number;
  vmGibSeconds?: number;
  /// What the spend would take a person, in minutes: the page shows cost as time, never money.
  costAsTimeMinutes?: number;
  /// On the `USAGE_OTHERS_KEY` row: how many people it folds.
  foldedPeople?: number;
  /// The platform's flag for a row far past the team's agent minutes per PR.
  outlier?: boolean;
};

export type UsageExportTotals = UsageExportMeasures & {
  /// Agent minutes per landed PR over the whole range, as the platform divides it.
  minutesPerPr?: number;
};

/// One slice of a drill-down: the rows of `group` = `key`.
export type UsageDrillStep = { group: UsageGroup; key: string; label?: string };

/// What a read asks for: the audit's params plus a drill-down's slice. Only an export read sends
/// `where`; the audit refuses unknown groupings and never gets one.
export type UsageReadParams = {
  since: string;
  until: string;
  groupBy: UsageGroup;
  format: "json" | "csv";
  where?: Record<string, string>;
};

/// What the export answers per row and in total, over the audit's fields.
export type UsageRowFields = TeamAuditTotals & UsageExportMeasures;
