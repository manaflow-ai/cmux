import type { AcpmuxRow, AcpmuxTamperingFile, AcpmuxTamperingFinding, AcpmuxTamperingReport } from "../model";

export type TamperingEvidence = AcpmuxTamperingFinding & {
  path: string;
  eventSeq?: number;
  fileIndex: number;
  findingIndex: number;
};

/** One disclosure per edited turn, with stable ordering across tool-call updates. */
export function tamperingForRows(rows: readonly AcpmuxRow[]): TamperingEvidence[] {
  const evidence: TamperingEvidence[] = [];
  const seen = new Set<string>();
  for (const row of rows) {
    // A failed edit is not evidence of a change on disk. Keep this guard here as well as in the
    // daemon restore path: replay can contain a failed update followed by the successful one.
    if (row.failed) continue;
    const turnKey = row.turnId ?? row.id;
    if (row.kind !== "activity" && row.kind !== "testTampering") continue;
    for (const item of row.items ?? []) {
      if (item.tool?.status === "failed") continue;
      const report: AcpmuxTamperingReport | undefined = item.tool?.tampering;
      for (const [fileIndex, file] of (report?.files ?? []).entries()) {
        const normalized: AcpmuxTamperingFile = file;
        for (const [findingIndex, finding] of (normalized.findings ?? []).entries()) {
          // Updates for one tool call can be replayed under different row versions. Include the
          // turn identity so identical evidence in two turns remains two alarms.
          const key = `${turnKey}\u0000${normalized.path}\u0000${finding.kind}\u0000${finding.line}\u0000${finding.old}\u0000${finding.new}`;
          if (seen.has(key)) continue;
          seen.add(key);
          evidence.push({
            ...finding,
            path: normalized.path,
            eventSeq: item.tool?.tamperingEventSeq,
            fileIndex,
            findingIndex,
          });
        }
      }
    }
  }
  return evidence;
}

export function hunkLines(finding: TamperingEvidence): string[] {
  return [
    ...finding.old
      .split("\n")
      .filter((line) => line.length > 0)
      .map((line) => `-${line}`),
    ...finding.new
      .split("\n")
      .filter((line) => line.length > 0)
      .map((line) => `+${line}`),
  ];
}
