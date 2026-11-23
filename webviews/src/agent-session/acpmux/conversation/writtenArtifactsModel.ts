import type { AcpmuxRow } from "../model";
import { type Artifact } from "./artifactPreview";
import { toolArtifacts } from "./artifactWrites";
import { PrefixFold } from "./prefixFlatMap";

export function writtenArtifacts(rows: readonly AcpmuxRow[]): Artifact[] {
  return rows.flatMap((row) => (row.items ?? []).flatMap((item) => (item.tool ? toolArtifacts(item.tool) : [])));
}
/// A file's last completed write and when its tool ended (unset for a recording without end times).
export type LatestWrite = { readonly artifact: Artifact; readonly endedAt?: number };
/// Each file's last completed write, by when its tool ended rather than where its row sits: two
/// concurrent writes to one file end in the order their contents landed. Without both end times the
/// later write in the transcript wins.
/// Read on every update while Session Info shows and while a written file is open beside the chat:
/// each row's writes are read once (kept by the row's object and its items), the rows again only past
/// the prefix an update kept, and the files listed again only when the writes changed (PrefixFold).
export function latestWrittenArtifacts(rows: readonly AcpmuxRow[]): ReadonlyMap<string, LatestWrite> {
  return latestWrites.read(rows);
}

const NO_WRITES: readonly LatestWrite[] = [];
const perRow = new WeakMap<
  AcpmuxRow,
  { readonly items: AcpmuxRow["items"]; readonly writes: readonly LatestWrite[] }
>();
function rowWrites(row: AcpmuxRow): readonly LatestWrite[] {
  if (!row.items?.length) return NO_WRITES;
  const kept = perRow.get(row);
  if (kept?.items === row.items) return kept.writes;
  const writes: LatestWrite[] = [];
  for (const item of row.items) {
    const tool = item.tool;
    if (tool) for (const artifact of toolArtifacts(tool)) writes.push({ artifact, endedAt: tool.endedAt });
  }
  const found = writes.length ? writes : NO_WRITES;
  perRow.set(row, { items: row.items, writes: found });
  return found;
}

const latestWrites = new PrefixFold<AcpmuxRow, LatestWrite, ReadonlyMap<string, LatestWrite>>(rowWrites, (writes) => {
  const latest = new Map<string, LatestWrite>();
  for (const write of writes) {
    const current = latest.get(write.artifact.path!);
    if (current?.endedAt !== undefined && write.endedAt !== undefined && write.endedAt < current.endedAt) continue;
    latest.set(write.artifact.path!, write);
  }
  return latest;
});
