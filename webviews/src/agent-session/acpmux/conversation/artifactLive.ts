// One opened fence's live source. Opening may inspect history; a streamed delta reads only its
// indexed row and at most the bounded set of historical versions, never the whole transcript.
import { type Artifact } from "./artifactPreview";
import { rowUpdates, type RowUpdates } from "../rowUpdates";
import type { AcpmuxRow } from "../model";
import { artifactForIdentity, artifactVersions, type ArtifactSourceRow } from "./artifactVersions";
import { latestWrittenArtifacts, type LatestWrite } from "./writtenArtifacts";

const VERSION_LIMIT = 64;

export class ArtifactLiveSource {
  private index = -1;
  private length = 0;
  private accepted: Artifact;
  private versions: Artifact[] = [];
  private liveIndex = 0;
  private rowId = "";
  private producer?: RowUpdates;
  private sourceRevision = -Infinity;
  private disposed = false;

  constructor(opened: Artifact, rows: readonly ArtifactSourceRow[]) {
    this.accepted = opened;
    this.rowId = opened.identity?.split("\u0000")[0] ?? "";
    this.index = rows.findIndex((row) => row.id === this.rowId);
    this.length = rows.length;
    this.versions = artifactVersions(
      rows.flatMap((row) => (row.kind === "assistant" && row.text ? [row.text] : [])),
      opened,
    ).slice(-VERSION_LIMIT);
    this.liveIndex = this.versions.findIndex((version) => version.code === opened.code);
    if (this.liveIndex < 0) {
      if (this.versions.length === VERSION_LIMIT) this.versions.shift();
      this.liveIndex = this.versions.push(opened) - 1;
    }
    // The displayed code can lag the full source while the reveal drains at this same revision.
    this.read(rows);
  }

  read(rows: readonly ArtifactSourceRow[]) {
    if (this.disposed) return { artifact: this.accepted, versions: this.versions };
    const producer = rowUpdates(rows);
    if (producer && producer !== this.producer) {
      if (this.producer && producer.generation < this.producer.generation)
        return { artifact: this.accepted, versions: this.versions };
      this.producer = producer;
      this.sourceRevision = -Infinity;
    } else if (!producer && this.producer) return { artifact: this.accepted, versions: this.versions };
    if (rows[this.index]?.id !== this.rowId) {
      // A backward page moves existing rows by exactly the number added above them. New rows
      // appended below leave the old position unchanged; neither case scans loaded history.
      const shifted = this.index + rows.length - this.length;
      this.index = rows[shifted]?.id === this.rowId ? shifted : -1;
    }
    this.length = rows.length;
    const row = producer?.rowOf(this.rowId) ?? rows[this.index];
    const revision = row ? (producer?.orderOf(row as AcpmuxRow) ?? row.version) : -Infinity;
    const next =
      row && revision > this.sourceRevision && this.accepted.identity
        ? artifactForIdentity([row], this.accepted.identity)
        : undefined;
    if (next) {
      this.sourceRevision = revision;
      // Fold-local row versions can restart when a bounded tail is replayed. The producer's event
      // revision rejects stale content; the panel's own revision remains monotonic across handoff.
      this.accepted = {
        ...this.accepted,
        ...next,
        revision: Math.max((this.accepted.revision ?? 0) + 1, next.revision ?? 0),
      };
      this.versions = this.versions.map((version, index) => (index === this.liveIndex ? this.accepted : version));
    }
    return { artifact: this.accepted, versions: this.versions };
  }
  dispose() {
    this.disposed = true;
  }
}

/// An opened written file follows the file's later completed writes: the panel's live choice moves
/// to each rewrite that ends after the one it shows, and a chosen older version stays put
/// (ArtifactPanel). Failed or partial writes never replace it (toolArtifacts reads completed ones).
/// Its versions are the transcript scan's (App.tsx), so it lists none of its own.
export class WrittenArtifactLive {
  private accepted: Artifact;
  private seen?: LatestWrite;
  private disposed = false;

  constructor(opened: Artifact, rows: readonly AcpmuxRow[]) {
    this.accepted = { ...opened, identity: `file:${opened.path}`, revision: 0 };
    // Opening an earlier write shows it; only writes that end after opening move the panel on.
    this.seen = latestWrittenArtifacts(rows).get(opened.path!);
  }

  read(rows: readonly AcpmuxRow[]): { artifact: Artifact; versions: readonly Artifact[] } {
    if (this.disposed) return { artifact: this.accepted, versions: [] };
    const latest = latestWrittenArtifacts(rows).get(this.accepted.path!);
    const seen = this.seen;
    if (latest && latest.artifact.code !== seen?.artifact.code) {
      // Never move back: a replayed tail after a reconnect can end before the write already shown,
      // and an older end time never replaces a newer one, whatever produced the rows.
      const older = seen?.endedAt !== undefined && (latest.endedAt === undefined || latest.endedAt < seen.endedAt);
      if (!older) {
        this.seen = latest;
        if (latest.artifact.code !== this.accepted.code)
          this.accepted = {
            ...latest.artifact,
            identity: this.accepted.identity,
            revision: (this.accepted.revision ?? 0) + 1,
          };
      }
    }
    return { artifact: this.accepted, versions: [] };
  }
  dispose() {
    this.disposed = true;
  }
}

/// The live source for an opened document: a streamed fence follows its row, a written file its
/// later completed writes. Others (a render card, a pasted document) have none.
export function artifactLiveSource(
  opened: Artifact,
  rows: readonly AcpmuxRow[],
): ArtifactLiveSource | WrittenArtifactLive | undefined {
  if (opened.path) return new WrittenArtifactLive(opened, rows);
  return opened.identity ? new ArtifactLiveSource(opened, rows) : undefined;
}

/// The live source's versions plus any finished versions a transcript scan found that it lacks: a
/// rewrite a later reply finished after opening goes after them, one a newly paged older reply
/// holds goes before them. Bounded like the live list.
export function mergeArtifactVersions(
  live: readonly Artifact[],
  scanned: readonly Artifact[] | undefined,
): readonly Artifact[] {
  if (!scanned?.length) return live;
  const codes = new Set(live.map((version) => version.code));
  const fresh = (version: Artifact) => !codes.has(version.code);
  const first = scanned.findIndex((version) => codes.has(version.code));
  const before = first < 0 ? [] : scanned.slice(0, first).filter(fresh);
  const after = (first < 0 ? scanned : scanned.slice(first)).filter(fresh);
  if (!before.length && !after.length) return live;
  return [...before, ...live, ...after].slice(-VERSION_LIMIT);
}
