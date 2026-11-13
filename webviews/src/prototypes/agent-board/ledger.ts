// l10n-allow-file: gallery prototype model, not shipped UI.
// Agent Board ledger: the JSONL an agent appends under the work-tracking skill
// (skills/work-tracking/SKILL.md), folded into what the board draws.

export type CapabilityStatus = "building" | "done" | "dropped";
export type PermutationStatus = "verified" | "unverified" | "broken";
export type EvidenceType = "screenshot" | "video" | "test" | "build" | "log" | "link";

export type TaskRecord = { kind: "task"; id: string; title: string; goal?: string; branch?: string; pr?: string };
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

/** A line the board could not read: shown as an error row, never dropped silently. */
export type LedgerProblem = { line: number; text: string; reason: string };

export type Board = {
  task?: TaskRecord;
  capabilities: CapabilityRecord[];
  decisions: DecisionRecord[];
  permutations: PermutationRecord[];
  evidence: Map<string, EvidenceRecord>;
  /** Record id → the order it was last written (the board's timeline). */
  order: Map<string, number>;
  problems: LedgerProblem[];
};

const KINDS = new Set(["task", "capability", "decision", "permutation", "evidence"]);
const ID = /^[a-z0-9]+(-[a-z0-9]+)*$/;

function problem(record: Record<string, unknown>): string | null {
  const kind = record.kind;
  if (typeof kind !== "string" || !KINDS.has(kind)) return "unknown kind";
  if (typeof record.id !== "string" || !ID.test(record.id)) return "id must be lower kebab case";
  switch (kind) {
    case "task":
    case "capability":
      return typeof record.title === "string" ? null : "missing title";
    case "decision":
      return typeof record.title === "string" && typeof record.chosen === "string" ? null : "missing title or chosen";
    case "permutation":
      return typeof record.for === "string" && record.axes && typeof record.axes === "object"
        ? null
        : "missing for or axes";
    case "evidence":
      return typeof record.path === "string" || typeof record.url === "string" ? null : "missing path or url";
  }
  return null;
}

/** Folds ledger text into a board. A later line with the same id replaces the earlier record. */
export function foldLedger(text: string): Board {
  const latest = new Map<string, LedgerRecord>();
  const order = new Map<string, number>();
  const problems: LedgerProblem[] = [];
  let seq = 0;
  text.split("\n").forEach((raw, index) => {
    const line = raw.trim();
    if (!line) return;
    let parsed: unknown;
    try {
      parsed = JSON.parse(line);
    } catch {
      problems.push({ line: index + 1, text: line, reason: "not JSON" });
      return;
    }
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      problems.push({ line: index + 1, text: line, reason: "not an object" });
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
    order.set(record.id as string, seq++);
  });
  const board: Board = { capabilities: [], decisions: [], permutations: [], evidence: new Map(), order, problems };
  for (const record of latest.values()) {
    if (record.kind === "task") board.task = record;
    else if (record.kind === "capability") board.capabilities.push({ ...record, status: record.status ?? "building" });
    else if (record.kind === "decision") board.decisions.push(record);
    else if (record.kind === "permutation") board.permutations.push({ ...record, status: record.status ?? "unverified" });
    else board.evidence.set(record.id, record);
  }
  const at = (id: string) => order.get(id) ?? 0;
  board.capabilities.sort((a, b) => at(a.id) - at(b.id));
  board.decisions.sort((a, b) => at(a.id) - at(b.id));
  board.permutations.sort((a, b) => at(a.id) - at(b.id));
  return board;
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

/** Evidence older than the newest SHA the ledger names is stale: it proves an earlier head. */
export function headSha(board: Board): string | undefined {
  let best: { sha: string; at: number } | undefined;
  for (const e of board.evidence.values()) {
    if (!e.sha) continue;
    const at = board.order.get(e.id) ?? 0;
    if (!best || at > best.at) best = { sha: e.sha, at };
  }
  return best?.sha;
}

export function isStale(board: Board, evidence: EvidenceRecord): boolean {
  const head = headSha(board);
  return Boolean(head && evidence.sha && evidence.sha !== head);
}

export function axesLabel(axes: Record<string, string>): string {
  return Object.values(axes).join(" · ");
}
