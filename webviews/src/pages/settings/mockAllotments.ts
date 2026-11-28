// l10n-allow-file: mock fixtures (sample member names), not shipped UI.
// Settings > Team > Compute's mock backend: a seven-seat team (two heavy members, one medium, one
// light, two agents seats and one member who used nothing) in each state the card draws, and the
// `cmux.settings.cloud.allotment.set` the mock provider answers. The native side does not exist yet,
// so this is the op's only implementation; it follows the backend's rules: up and down apply the
// proposal's commit (the other direction moves one $25 step), hold snoozes proposals 14 days.
import type { AllotmentDecision, AllotmentSet, AllotmentView, MemberUse, TeamAllotment } from "./ops";
import { commitFor, SEAT_MICROS } from "./computeAllotment";

const usd = (dollars: number) => Math.round(dollars * 1_000_000);
const DAY_MS = 86_400_000;
/** 2026-11-22, noon UTC: the fixtures' clock. */
export const MOCK_AS_OF = Date.UTC(2026, 10, 22, 12);

type Use = Pick<MemberUse, "member" | "tier"> & Partial<MemberUse>;

function member(use: Use, share: number): MemberUse {
  return {
    month_micros: 0,
    usd14_micros: 0,
    active_days14: 0,
    rank: 0,
    over_share14: 0,
    plan_limit_ms14: 0,
    spare_micros: 0,
    share_micros: share,
    ...use,
  };
}

/** The team's seven seats with this month's and the last 14 days' use. */
function team(uses: Use[], allot: number): MemberUse[] {
  const share = Math.round(allot / uses.length);
  const members = uses.map((use) => member(use, share));
  const ranked = [...members].sort((a, b) => b.usd14_micros - a.usd14_micros);
  return members.map((row) => ({ ...row, rank: ranked.indexOf(row) + 1 }));
}

const TIERS = { Leo: "max", Lawrence: "plus" } as const;
/** Tier credits the two Chief tiers add to the allotment ($50 together). */
const TIER_CREDITS = usd(50);

function allotment(commit: number, extra: Partial<TeamAllotment> = {}): TeamAllotment {
  return {
    commit_micros: commit,
    mode: "ask",
    auto_max_micros: null,
    tiers: { ...TIERS },
    snoozed_until: null,
    changed_at: MOCK_AS_OF - 20 * DAY_MS,
    changed_by: "Leo",
    ...extra,
  };
}

const busy: Use[] = [
  { member: "Leo", tier: "max", month_micros: usd(96), usd14_micros: usd(71), active_days14: 13, spare_micros: usd(6) },
  { member: "Lawrence", tier: "plus", month_micros: usd(88), usd14_micros: usd(64), active_days14: 12 },
  {
    member: "Austin",
    tier: "standard",
    month_micros: usd(61),
    usd14_micros: usd(52),
    active_days14: 11,
    over_share14: 4,
  },
  { member: "Aziz", tier: "standard", month_micros: usd(14), usd14_micros: usd(9), active_days14: 4 },
  {
    member: "Agents: CI",
    tier: "standard",
    month_micros: usd(42),
    usd14_micros: usd(31),
    active_days14: 14,
    spare_micros: usd(9),
  },
  { member: "Agents: lanes", tier: "standard", month_micros: usd(23), usd14_micros: usd(17), active_days14: 9 },
  { member: "Sam", tier: "standard" },
];

const quiet: Use[] = [
  { member: "Leo", tier: "max", month_micros: usd(58), usd14_micros: usd(40), active_days14: 10, spare_micros: usd(4) },
  { member: "Lawrence", tier: "plus", month_micros: usd(47), usd14_micros: usd(33), active_days14: 9 },
  { member: "Austin", tier: "standard", month_micros: usd(19), usd14_micros: usd(12), active_days14: 5 },
  { member: "Aziz", tier: "standard", month_micros: usd(3) },
  {
    member: "Agents: CI",
    tier: "standard",
    month_micros: usd(26),
    usd14_micros: usd(18),
    active_days14: 14,
    spare_micros: usd(5),
  },
  { member: "Agents: lanes", tier: "standard", month_micros: usd(2) },
  { member: "Sam", tier: "standard" },
];

const SEATS = busy.length;
const INCLUDED = SEATS * SEAT_MICROS;
const allotFor = (commit: number) => INCLUDED + TIER_CREDITS + commit;

function view(
  commit: number,
  uses: Use[],
  decision: Omit<AllotmentDecision, "allot_micros" | "members" | "order" | "apply"> & { apply?: boolean },
  extra: Partial<TeamAllotment> = {},
): AllotmentView {
  const allot = allotFor(commit);
  const members = team(uses, allot);
  return {
    allotment: allotment(commit, extra),
    decision: {
      allot_micros: allot,
      members,
      order: members.map((row) => row.member),
      apply: false,
      ...decision,
    },
    hard_cap_micros: usd(500),
    as_of: MOCK_AS_OF,
  };
}

/** Austin passed the allotment 4 times: the scheduler proposes two more $25 steps ($40 a month). */
const proposalUp = view(usd(75), busy, {
  forecast_micros: usd(372),
  position: "up",
  to_commit_micros: usd(125),
  reasons: [
    { kind: "over", member: "Austin", count: 4 },
    { kind: "tier", member: "Austin", to: "plus", costs_micros: usd(40) },
  ],
});

/** Three of seven used nothing in 14 days: two steps fewer saves $40 a month. */
const proposalDown = view(usd(75), quiet, {
  forecast_micros: usd(174),
  position: "down",
  to_commit_micros: usd(25),
  reasons: [{ kind: "unused", members: ["Aziz", "Agents: lanes", "Sam"] }],
});

/** Usage fits: nothing to decide. */
const fits: Use[] = [
  { member: "Leo", tier: "max", month_micros: usd(82), usd14_micros: usd(58), active_days14: 12, spare_micros: usd(5) },
  { member: "Lawrence", tier: "plus", month_micros: usd(70), usd14_micros: usd(49), active_days14: 11 },
  { member: "Austin", tier: "standard", month_micros: usd(41), usd14_micros: usd(30), active_days14: 8 },
  { member: "Aziz", tier: "standard", month_micros: usd(12), usd14_micros: usd(8), active_days14: 3 },
  {
    member: "Agents: CI",
    tier: "standard",
    month_micros: usd(38),
    usd14_micros: usd(27),
    active_days14: 14,
    spare_micros: usd(7),
  },
  { member: "Agents: lanes", tier: "standard", month_micros: usd(21), usd14_micros: usd(15), active_days14: 7 },
  { member: "Sam", tier: "standard" },
];

/** Usage fits: nothing to decide. */
const hold = view(usd(75), fits, {
  forecast_micros: usd(288),
  position: "hold",
  to_commit_micros: usd(75),
  reasons: [],
});

/** No one has used Cloud yet: seven seats include $175, and no allotment was ever set. */
const empty: AllotmentView = {
  allotment: null,
  decision: {
    allot_micros: INCLUDED,
    forecast_micros: 0,
    position: "hold",
    to_commit_micros: 0,
    reasons: [],
    members: team(
      busy.map(({ member: name }) => ({ member: name, tier: "standard" as const })),
      INCLUDED,
    ),
    order: busy.map((use) => use.member),
    apply: false,
  },
  hard_cap_micros: null,
  as_of: MOCK_AS_OF,
};

/** Auto on, up to $200 of commit: the CI agents run away at $9 an hour; the scheduler applies it. */
const autoOn = view(
  usd(75),
  busy,
  {
    forecast_micros: usd(390),
    position: "up",
    to_commit_micros: usd(125),
    apply: true,
    reasons: [
      { kind: "runaway", member: "Agents: CI", rate_micros_h: usd(9) },
      { kind: "over", member: "Austin", count: 4 },
    ],
  },
  { mode: "auto", auto_max_micros: usd(200) },
);

export const mockAllotments = { proposalUp, proposalDown, hold, empty, autoOn } satisfies Record<string, AllotmentView>;

export type MockAllotmentState = keyof typeof mockAllotments;

/** The backend's answer to one set: the view after it. A set with no action only
 * changes the mode (the Auto switch); hold snoozes proposals 14 days. */
export function runMockAllotment(view: AllotmentView, run: AllotmentSet, by = "Leo"): AllotmentView {
  const before = view.allotment ?? allotment(0, { tiers: {}, changed_at: view.as_of });
  const before0 = view.allotment?.commit_micros ?? 0;
  const onlyMode = run.action === undefined;
  const commit = run.action === undefined ? before0 : commitFor(view, run.action);
  const next: TeamAllotment = {
    ...before,
    commit_micros: commit,
    mode: run.auto === undefined ? before.mode : run.auto ? "auto" : "ask",
    snoozed_until: run.action === "hold" ? view.as_of + 14 * DAY_MS : before.snoozed_until,
    changed_at: view.as_of,
    changed_by: by,
  };
  if (run.person_hold_seconds === null) delete next.person_hold_seconds;
  else if (run.person_hold_seconds !== undefined) next.person_hold_seconds = run.person_hold_seconds;
  if (onlyMode) return { ...view, allotment: next };
  const allot = view.decision.allot_micros - before.commit_micros + commit;
  return {
    ...view,
    allotment: next,
    decision: {
      ...view.decision,
      allot_micros: allot,
      position: "hold",
      to_commit_micros: commit,
      reasons: [],
      apply: false,
    },
  };
}
