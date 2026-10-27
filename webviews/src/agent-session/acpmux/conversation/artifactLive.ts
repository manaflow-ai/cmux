// One opened fence's live source. Opening may inspect history; a streamed delta reads only its
// indexed row and at most the bounded set of historical versions, never the whole transcript.
import { type Artifact } from "./artifactPreview";
import { rowUpdates } from "../rowUpdates";
import { ArtifactWrittenLive } from "./artifactWrittenLive";
import { artifactForIdentity, artifactVersions, type ArtifactSourceRow } from "./artifactVersions";

const VERSION_LIMIT = 64;

export class ArtifactLiveSource {
  private index = -1;
  private length = 0;
  private accepted: Artifact;
  private versions: Artifact[] = [];
  private liveIndex = 0;
  private rowId = "";
  private written?: ArtifactWrittenLive;

  constructor(opened: Artifact, rows: readonly ArtifactSourceRow[]) {
    this.accepted = opened;
    if (opened.path) {
      this.written = new ArtifactWrittenLive(opened, rows);
      return;
    }
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
    this.read(rows, (opened.revision ?? -Infinity) - 1);
  }

  read(rows: readonly ArtifactSourceRow[], after = this.accepted.revision ?? -Infinity) {
    if (this.written) return this.written.read(rows);
    if (rows[this.index]?.id !== this.rowId) {
      // A backward page moves existing rows by exactly the number added above them. New rows
      // appended below leave the old position unchanged; neither case scans loaded history.
      const shifted = this.index + rows.length - this.length;
      this.index = rows[shifted]?.id === this.rowId ? shifted : -1;
    }
    this.length = rows.length;
    const row = rowUpdates(rows)?.rowOf(this.rowId) ?? rows[this.index];
    const next = row && this.accepted.identity ? artifactForIdentity([row], this.accepted.identity, after) : undefined;
    if (next) {
      this.accepted = { ...this.accepted, ...next };
      this.versions = this.versions.map((version, index) => (index === this.liveIndex ? this.accepted : version));
    }
    return { artifact: this.accepted, versions: this.versions };
  }
  dispose() {
    this.written?.dispose();
  }
}
