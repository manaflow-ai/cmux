import type { AcpmuxRow } from "../model";
import { type Artifact } from "./artifactPreview";
import { toolArtifacts } from "./artifactWrites";

export function writtenArtifacts(rows: readonly AcpmuxRow[]): Artifact[] {
  return rows.flatMap((row) => (row.items ?? []).flatMap((item) => (item.tool ? toolArtifacts(item.tool) : [])));
}
/// A file's last completed write and when its tool ended (unset for a recording without end times).
export type LatestWrite = { readonly artifact: Artifact; readonly endedAt?: number };
/// Each file's last completed write, by when its tool ended rather than where its row sits: two
/// concurrent writes to one file end in the order their contents landed. Without both end times the
/// later write in the transcript wins.
export function latestWrittenArtifacts(rows: readonly AcpmuxRow[]): Map<string, LatestWrite> {
  const latest = new Map<string, LatestWrite>();
  for (const row of rows)
    for (const item of row.items ?? []) {
      const tool = item.tool;
      if (!tool) continue;
      for (const artifact of toolArtifacts(tool)) {
        const current = latest.get(artifact.path!);
        if (current?.endedAt !== undefined && tool.endedAt !== undefined && tool.endedAt < current.endedAt) continue;
        latest.set(artifact.path!, { artifact, endedAt: tool.endedAt });
      }
    }
  return latest;
}
