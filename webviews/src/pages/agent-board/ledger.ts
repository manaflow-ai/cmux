// Agent Board ledger: the JSONL an agent appends under the work-tracking skill
// (skills/work-tracking/SKILL.md), folded into what the board draws.

export type CapabilityStatus = "building" | "done" | "dropped";
export type PermutationStatus = "verified" | "unverified" | "broken";
export type EvidenceType = "screenshot" | "video" | "test" | "build" | "log" | "link";

export type TaskRecord = {
  kind: "task";
  id: string;
  title: string;
  goal?: string;
  branch?: string;
  pr?: string;
  /** The agent that keeps the ledger (`Claude Code`, `Codex`). */
  agent?: string;
  /** The cmux workspace it works in. */
  workspace?: string;
};
export type CapabilityRecord = {
  kind: "capability";
  id: string;
  title: string;
  summary?: string;
  area?: string;
  status: CapabilityStatus;
  files?: string[];
};
export type DecisionRecord = {
  kind: "decision";
  id: string;
  title: string;
  chosen: string;
  why?: string;
  rejected?: { option: string; why?: string }[];
  for?: string[];
  needsHuman?: boolean;
};
export type PermutationRecord = {
  kind: "permutation";
  id: string;
  for: string;
  axes: Record<string, string>;
  status: PermutationStatus;
  evidence?: string[];
  note?: string;
};
export type EvidenceRecord = {
  kind: "evidence";
  id: string;
  type: EvidenceType;
  path?: string;
  url?: string;
  caption?: string;
  sha?: string;
  for?: string[];
};
export type LedgerRecord = TaskRecord | CapabilityRecord | DecisionRecord | PermutationRecord | EvidenceRecord;

/** A line the board could not read: shown as an error row, never dropped silently. `reason` is
 * `json` (not JSON), `object` (not an object), or the name of the field that is missing or wrong. */
export type LedgerProblem = { line: number; text: string; reason: string };

export type Board = {
  task?: TaskRecord;
  capabilities: CapabilityRecord[];
  decisions: DecisionRecord[];
  permutations: PermutationRecord[];
  evidence: Map<string, EvidenceRecord>;
  /** `kind:id` → the line order it first appeared at: list order and the Story timeline. */
  order: Map<string, number>;
  /** The newest commit the ledger names: the SHA on the last line that introduced a new one. */
  head?: string;
  problems: LedgerProblem[];
};

const KINDS = new Set(["task", "capability", "decision", "permutation", "evidence"]);
const ID = /^[a-z0-9]+(-[a-z0-9]+)*$/;
const CAPABILITY_STATUS = new Set(["building", "done", "dropped"]);
const PERMUTATION_STATUS = new Set(["verified", "unverified", "broken"]);
const EVIDENCE_TYPE = new Set(["screenshot", "video", "test", "build", "log", "link"]);

const isString = (v: unknown): v is string => typeof v === "string";
const optional = (v: unknown, check: (v: unknown) => boolean) => v === undefined || check(v);
const stringList = (v: unknown) => Array.isArray(v) && v.every(isString);
const stringMap = (v: unknown) =>
  Boolean(v) && typeof v === "object" && !Array.isArray(v) && Object.values(v as object).every(isString);
const oneOf = (set: Set<string>) => (v: unknown) => isString(v) && set.has(v);

/** The field that keeps a parsed line from being drawn, or null. Every field the board reads is type-checked, so a
 * wrong type becomes an error row instead of breaking the page. */
function problem(r: Record<string, unknown>): string | null {
  if (!oneOf(KINDS)(r.kind)) return "kind";
  if (!isString(r.id) || !ID.test(r.id)) return "id";
  for (const key of [
    "title",
    "summary",
    "area",
    "goal",
    "branch",
    "pr",
    "agent",
    "workspace",
    "chosen",
    "why",
    "note",
    "path",
    "url",
    "caption",
    "sha",
  ])
    if (!optional(r[key], isString)) return key;
  switch (r.kind) {
    case "task":
      return isString(r.title) ? null : "title";
    case "capability":
      if (!isString(r.title)) return "title";
      if (!optional(r.status, oneOf(CAPABILITY_STATUS))) return "status";
      return optional(r.files, stringList) ? null : "files";
    case "decision":
      if (!isString(r.title) || !isString(r.chosen)) return "chosen";
      if (!optional(r.for, stringList)) return "for";
      if (!optional(r.needsHuman, (v) => typeof v === "boolean")) return "needsHuman";
      return optional(
        r.rejected,
        (v) =>
          Array.isArray(v) &&
          v.every((o) => o && typeof o === "object" && isString(o.option) && optional(o.why, isString)),
      )
        ? null
        : "rejected";
    case "permutation":
      if (!isString(r.for)) return "for";
      if (!stringMap(r.axes)) return "axes";
      if (!optional(r.status, oneOf(PERMUTATION_STATUS))) return "status";
      return optional(r.evidence, stringList) ? null : "evidence";
    case "evidence":
      if (!oneOf(EVIDENCE_TYPE)(r.type)) return "type";
      if (!isString(r.path) && !isString(r.url)) return "path";
      return optional(r.for, stringList) ? null : "for";
  }
  return null;
}

const sameCommit = (a: string, b: string) => a.startsWith(b) || b.startsWith(a);

/** Folds ledger text into a board. A later line with the same kind and id replaces that record and
 * keeps its first position. */
export function foldLedger(text: string): Board {
  const latest = new Map<string, LedgerRecord>();
  const order = new Map<string, number>();
  const problems: LedgerProblem[] = [];
  const seen: string[] = [];
  let head: string | undefined;
  text.split("\n").forEach((raw, index) => {
    const line = raw.trim();
    if (!line) return;
    let parsed: unknown;
    try {
      parsed = JSON.parse(line);
    } catch {
      problems.push({ line: index + 1, text: line, reason: "json" });
      return;
    }
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      problems.push({ line: index + 1, text: line, reason: "object" });
      return;
    }
    const record = parsed as Record<string, unknown>;
    const reason = problem(record);
    if (reason) {
      problems.push({ line: index + 1, text: line, reason });
      return;
    }
    const key = `${record.kind as string}:${record.id as string}`;
    latest.set(key, record as LedgerRecord);
    if (!order.has(key)) order.set(key, order.size);
    if (record.kind === "evidence" && isString(record.sha) && !seen.some((s) => sameCommit(s, record.sha as string))) {
      seen.push(record.sha);
      head = record.sha;
    }
  });
  const board: Board = {
    capabilities: [],
    decisions: [],
    permutations: [],
    evidence: new Map(),
    order,
    head,
    problems,
  };
  for (const record of latest.values()) {
    if (record.kind === "task") board.task = record;
    else if (record.kind === "capability") board.capabilities.push({ ...record, status: record.status ?? "building" });
    else if (record.kind === "decision") board.decisions.push(record);
    else if (record.kind === "permutation")
      board.permutations.push({ ...record, status: record.status ?? "unverified" });
    else board.evidence.set(record.id, record);
  }
  return board;
}

/** Where a record first appeared in its ledger. */
export function orderOf(board: Board, record: LedgerRecord): number {
  return board.order.get(`${record.kind}:${record.id}`) ?? 0;
}

export type Coverage = { verified: number; unverified: number; broken: number; total: number };

export function coverage(permutations: readonly PermutationRecord[]): Coverage {
  const out: Coverage = { verified: 0, unverified: 0, broken: 0, total: permutations.length };
  for (const p of permutations) out[p.status] += 1;
  return out;
}

export function permutationsFor(board: Board, capability: string): PermutationRecord[] {
  return board.permutations.filter((p) => p.for === capability);
}

/** Evidence taken at a commit older than the ledger's newest one proves an earlier head. Short and
 * full SHAs of the same commit match. */
export function isStale(board: Board, evidence: EvidenceRecord): boolean {
  return Boolean(board.head && evidence.sha && !sameCommit(evidence.sha, board.head));
}

export function axesLabel(axes: Record<string, string>): string {
  return Object.values(axes).join(" · ");
}
