/**
 * Palette ranking eval (plans/cmux-next/palette-ranking.md section 3).
 *
 * Replays real root-palette entries (dumped from a tagged build with
 * `debug.palette.entries`) through the shared ranker for a fixed set of
 * queries with expected rows, and reports top-1, top-3 and MRR. Ranking
 * changes are measured against this report, not guessed.
 */
import {
  rankPalette,
  type PaletteFrecency,
  type PaletteLearnedPick,
  type PaletteRankEntry,
  type PaletteRankRequest,
} from "./ranker";

export interface EvalFixtureEntry {
  id: string;
  entry: PaletteRankEntry;
}

export interface EvalFixtureSection {
  id: string;
  title: string;
  order: number;
}

/** The ranker input of one scope, as `debug.palette.entries` writes it. */
export interface EvalFixture {
  scope: string;
  showsRecent: boolean;
  sectionOrders: number[];
  sections: EvalFixtureSection[];
  entries: EvalFixtureEntry[];
}

/** Rows a fresh tagged build does not have (workspaces, tabs): added with their provider's shape. */
export interface EvalOverlayEntry extends EvalFixtureEntry {
  section: EvalFixtureSection;
}

export interface EvalCase {
  query: string;
  /** Any of these row ids is a correct answer; the first is the best one. */
  expect: string[];
  group: string;
  /** Rank with this usage profile (`profiles` of the cases file). */
  profile?: string;
  note?: string;
  /** A guard case: its row must stay in the top 3 (palette-eval.test.ts fails otherwise). */
  guard?: boolean;
  /** Learning: these runs happen first (oldest first), each `daysAgo` before the query. */
  replay?: Array<
    { query: string; pick: string; daysAgo?: number } | { hide: string } | { unhide: string } | { forget: string }
  >;
  /** Learning: this row must NOT be first (an old pick that should have faded). */
  notFirst?: string;
  /** Learning: this row must not be among the results at all (a hidden row). */
  absent?: string;
}

export interface EvalCases {
  /** Decayed use counts per frecency key, all last used at the eval's `now`. */
  profiles?: Record<string, Record<string, number>>;
  cases: EvalCase[];
}

export interface EvalCaseResult {
  query: string;
  group: string;
  profile?: string;
  /** 1-based rank of the first expected row in display order, null when absent from the first 50. */
  rank: number | null;
  top: string[];
  expect: string[];
}

export interface EvalReport {
  cases: number;
  top1: number;
  top3: number;
  mrr: number;
  byGroup: Record<string, { cases: number; top1: number; top3: number; mrr: number }>;
  results: EvalCaseResult[];
}

export type Ranker = (request: Omit<PaletteRankRequest, "operation">) => ReturnType<typeof rankPalette>;

export const evalNow = 800_000_000;

const day = 24 * 60 * 60;
const halfLife = 3 * day;
const pickHalfLife = 7 * day;

/**
 * The history the daemon would hold after `replay` (test-only model of
 * cmux-tui-core state/palette_usage.rs `record`: +1 per use with a 3-day
 * half-life, +1 per pick under each 1-8 character start of the normalized
 * query with a 7-day half-life, and the latest pick per start). The daemon
 * is the real writer; this lets the eval measure learning without one.
 */
export function replayHistory(replay: NonNullable<EvalCase["replay"]>, base: PaletteFrecency = {}): PaletteFrecency {
  const entries = { ...base.entries };
  let picks: PaletteLearnedPick[] = [...(base.picks ?? [])];
  const hidden = new Set(base.hidden ?? []);
  const decay = (score: number, from: number, to: number, life: number) =>
    score * 2 ** (-Math.max(0, to - from) / life);
  for (const event of replay) {
    // Row controls (the daemon's palette_usage.hide and palette_usage.forget).
    if ("hide" in event) {
      hidden.add(event.hide);
      continue;
    }
    if ("unhide" in event) {
      hidden.delete(event.unhide);
      continue;
    }
    if ("forget" in event) {
      delete entries[event.forget];
      picks = picks.filter((pick) => pick.key !== event.forget);
      continue;
    }
    const at = evalNow - (event.daysAgo ?? 0) * day;
    const entry = entries[event.pick];
    entries[event.pick] = { score: (entry ? decay(entry.score, entry.lastUsed, at, halfLife) : 0) + 1, lastUsed: at };
    const chars = Array.from(event.query.trim().split(/\s+/u).filter(Boolean).join(" ").toLowerCase());
    const prefixes = new Set<string>();
    for (let length = 1; length <= Math.min(chars.length, 8); length++) {
      const prefix = chars.slice(0, length).join("").trimEnd();
      if (prefix) prefixes.add(prefix);
    }
    for (const prefix of prefixes) {
      for (const pick of picks) if (pick.prefix === prefix) pick.last = false;
      const existing = picks.find((pick) => pick.prefix === prefix && pick.key === event.pick);
      if (existing) {
        existing.score = decay(existing.score, existing.lastUsed, at, pickHalfLife) + 1;
        existing.lastUsed = at;
        existing.last = true;
      } else picks.push({ prefix, key: event.pick, score: 1, lastUsed: at, last: true });
    }
  }
  return { entries, picks, halfLife, pickHalfLife, hidden: [...hidden] };
}

/** The fixture's entries plus the overlay rows, with section indexes resolved. */
export function mergeOverlay(fixture: EvalFixture, overlay: readonly EvalOverlayEntry[]): EvalFixture {
  const sections = [...fixture.sections];
  const entries = [...fixture.entries];
  for (const row of overlay) {
    let index = sections.findIndex((section) => section.id === row.section.id);
    if (index < 0) {
      index = sections.length;
      sections.push(row.section);
    }
    // A page that merges sections while typing puts the overlay rows there too.
    const typingSectionIndex = fixture.entries[0]?.entry.typingSectionIndex ?? null;
    entries.push({ id: row.id, entry: { ...row.entry, sectionIndex: index, typingSectionIndex } });
  }
  return { ...fixture, sections, sectionOrders: sections.map((section) => section.order), entries };
}

function frecencyFor(profile: Record<string, number> | undefined): PaletteFrecency {
  if (!profile) return { entries: {} };
  return {
    entries: Object.fromEntries(Object.entries(profile).map(([key, score]) => [key, { score, lastUsed: evalNow }])),
  };
}

/** Row ids in display order (sections in their order, rows in theirs). */
export function rankedIDs(fixture: EvalFixture, query: string, frecency: PaletteFrecency, rank: Ranker = rankPalette) {
  const entries = fixture.entries.map((row) => row.entry);
  return rank({
    entries,
    query,
    sectionOrders: fixture.sectionOrders,
    frecency,
    now: evalNow,
    showsRecent: fixture.showsRecent,
  }).flatMap((section) => section.rows.map((row) => fixture.entries[row.index].id));
}

function summarize(results: readonly EvalCaseResult[]) {
  const cases = results.length;
  const top1 = results.filter((result) => result.rank === 1).length;
  const top3 = results.filter((result) => result.rank !== null && result.rank <= 3).length;
  const reciprocal = results.reduce((sum, result) => sum + (result.rank ? 1 / result.rank : 0), 0);
  return {
    cases,
    top1: cases ? top1 / cases : 0,
    top3: cases ? top3 / cases : 0,
    mrr: cases ? reciprocal / cases : 0,
  };
}

/** Scores `ranked(query, profile)` (row ids, best first) against the cases. */
export function scoreCases(
  cases: EvalCases,
  ranked: (query: string, frecency: PaletteFrecency, evalCase: EvalCase) => readonly string[],
): EvalReport {
  const results = cases.cases.map((evalCase): EvalCaseResult => {
    const profile = evalCase.profile ? cases.profiles?.[evalCase.profile] : undefined;
    const frecency = evalCase.replay ? replayHistory(evalCase.replay, frecencyFor(profile)) : frecencyFor(profile);
    const ids = ranked(evalCase.query, frecency, evalCase).slice(0, 50);
    const position = evalCase.absent
      ? ids.includes(evalCase.absent)
        ? -1
        : 0
      : evalCase.notFirst
        ? ids[0] !== evalCase.notFirst
          ? 0
          : -1
        : ids.findIndex((id) => evalCase.expect.includes(id));
    return {
      query: evalCase.query,
      group: evalCase.group,
      profile: evalCase.profile,
      rank: position < 0 ? null : position + 1,
      top: ids.slice(0, 3),
      expect: evalCase.expect,
    };
  });
  const groups = [...new Set(results.map((result) => result.group))].sort();
  return {
    ...summarize(results),
    byGroup: Object.fromEntries(
      groups.map((group) => [group, summarize(results.filter((result) => result.group === group))]),
    ),
    results,
  };
}

export function evaluate(fixture: EvalFixture, cases: EvalCases, rank: Ranker = rankPalette): EvalReport {
  return scoreCases(cases, (query, frecency) => rankedIDs(fixture, query, frecency, rank));
}

const percent = (value: number) => `${(value * 100).toFixed(1)}%`;

/** A plain-text report: totals, per group, then every miss with what ranked first. */
export function formatReport(report: EvalReport, title = "palette eval"): string {
  const lines = [
    `${title}: ${report.cases} cases  top-1 ${percent(report.top1)}  top-3 ${percent(report.top3)}  MRR ${report.mrr.toFixed(3)}`,
  ];
  for (const [group, value] of Object.entries(report.byGroup)) {
    lines.push(
      `  ${group.padEnd(12)} ${String(value.cases).padStart(3)}  top-1 ${percent(value.top1).padStart(6)}  top-3 ${percent(value.top3).padStart(6)}  MRR ${value.mrr.toFixed(3)}`,
    );
  }
  const misses = report.results.filter((result) => result.rank !== 1);
  if (misses.length) lines.push("  not first:");
  for (const miss of misses) {
    const profile = miss.profile ? ` [${miss.profile}]` : "";
    lines.push(
      `    ${JSON.stringify(miss.query)}${profile} rank ${miss.rank ?? "-"}  want ${miss.expect[0]}  got ${miss.top.join(", ")}`,
    );
  }
  return lines.join("\n");
}
