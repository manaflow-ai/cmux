#!/usr/bin/env bun
// Follow verdicts: which shifting states move only by the follow a transcript makes on purpose, and
// which hold a real shift (Leo, 2026-11-18: the correctness of the layout shifts, without delay).
// The box score (shift-baseline.ts) cannot tell a bottom-pinned reply streaming from a row that
// jumps; the stage judges every phase's frames for that too (webviews/src/gallery/followJudge.ts,
// `boxFollow` on the load and each step). This reads a run's results.json and prints, per state
// (the worst of its cases), whether any frame held a stray move, and where: the step, the frame,
// the boxes and the px.
//
//   bun follow-verdict.ts <results.json>... [--states a#x,b#y] [--arm-key exp]
import { readFileSync } from "node:fs";
import { parseArgs } from "node:util";

type Stray = { label: string; frame: number; dx: number; dy: number; follow: number };
type Follow = { movingFrames: number; followFrames: number; strayFrames: number; stray: Stray[]; worst: number };
type Phase = { step?: string; boxFollow?: Follow | null } | null | undefined;
export type VerdictResult = {
  params?: Record<string, unknown>;
  ready?: string | null;
  load?: Phase;
  play?: { steps?: Phase[] } | null;
};

export type Verdict = {
  /** `arm<TAB>state`: the arm is `default` unless the case set one (`exp=arm`). */
  key: string;
  verdict: "follow only" | "real shift" | "not judged";
  movingFrames: number;
  strayFrames: number;
  /** The largest stray move in px. */
  worst: number;
  /** The first stray moves, by phase: "step, frame N: box [dx dy] (follow f)". */
  where: string[];
};

const keyOf = (result: VerdictResult): string => {
  const p = result.params ?? {};
  const arm = p.arm ? `${String(p.exp)}=${String(p.arm)}` : "default";
  return `${arm}\t${String(p.entry ?? "")}#${String(p.variant ?? "")}`;
};

/** One case's verdict: every phase's follow judgement folded. */
export function caseVerdict(result: VerdictResult): Verdict {
  const phases: { name: string; follow: Follow | null | undefined }[] = [
    { name: "load", follow: result.load?.boxFollow },
    ...(result.play?.steps ?? []).map((step) => ({ name: step?.step ?? "step", follow: step?.boxFollow })),
  ];
  const judged = phases.filter((phase) => phase.follow);
  let moving = 0;
  let stray = 0;
  let worst = 0;
  const where: string[] = [];
  for (const { name, follow } of judged) {
    moving += follow!.movingFrames;
    stray += follow!.strayFrames;
    worst = Math.max(worst, follow!.worst);
    for (const move of follow!.stray.slice(0, 3))
      if (where.length < 6)
        where.push(`${name.slice(0, 60)}, frame ${move.frame}: ${move.label} [${move.dx} ${move.dy}] (follow ${move.follow})`);
  }
  return {
    key: keyOf(result),
    verdict: judged.length === 0 ? "not judged" : stray > 0 ? "real shift" : "follow only",
    movingFrames: moving,
    strayFrames: stray,
    worst: Math.round(worst * 10) / 10,
    where,
  };
}

/** Each state's verdict in a run: the case with the largest stray move (or the most stray frames). */
export function stateVerdicts(results: VerdictResult[]): Map<string, Verdict> {
  const verdicts = new Map<string, Verdict>();
  for (const result of results) {
    if (result.ready !== "1") continue;
    const verdict = caseVerdict(result);
    const seen = verdicts.get(verdict.key);
    const worse =
      !seen ||
      (seen.verdict === "not judged" && verdict.verdict !== "not judged") ||
      verdict.worst > seen.worst ||
      (verdict.worst === seen.worst && verdict.strayFrames > seen.strayFrames);
    if (worse) verdicts.set(verdict.key, verdict);
  }
  return verdicts;
}

if (import.meta.main) {
  const { values, positionals } = parseArgs({
    args: Bun.argv.slice(2),
    allowPositionals: true,
    options: { states: { type: "string" } },
  });
  const results = positionals.flatMap((file) => JSON.parse(readFileSync(file, "utf8")) as VerdictResult[]);
  const wanted = values.states ? new Set(values.states.split(",")) : undefined;
  for (const [key, verdict] of stateVerdicts(results)) {
    if (wanted && !wanted.has(key.split("\t")[1]!) && !wanted.has(key)) continue;
    console.log(
      ["VERDICT", key, verdict.verdict, verdict.movingFrames, verdict.strayFrames, verdict.worst, verdict.where.join("; ")].join(
        "\t",
      ),
    );
  }
}
