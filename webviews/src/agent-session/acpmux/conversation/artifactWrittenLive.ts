// Follow canonical file identity, never a title or a filesystem read. Only the existing detector
// decides whether a completed tool recorded a complete document.
import type { AcpmuxRow } from "../model";
import { rowUpdates, type RowUpdate } from "../rowUpdates";
import type { Artifact } from "./artifactPreview";
import type { ArtifactSourceRow } from "./artifactVersions";
import { toolArtifacts } from "./artifactWrites";

export class ArtifactWrittenLive {
  private artifact: Artifact;
  private versions: Artifact[] = [];
  private order = -Infinity;
  private revision = 0;
  private unsubscribe?: () => void;
  private recent = new WeakSet<ArtifactSourceRow>();
  private disposed = false;

  constructor(opened: Artifact, rows: readonly ArtifactSourceRow[]) {
    this.artifact = { ...opened, identity: `file:${opened.path}`, revision: 0 };
    const producer = rowUpdates(rows);
    for (const row of rows) {
      this.recent.add(row);
      const order = producer?.orderOf(row as AcpmuxRow) ?? row.at ?? 0;
      for (const item of row.items ?? [])
        for (const artifact of item.tool ? toolArtifacts(item.tool) : []) {
          if (!this.matches(artifact)) continue;
          this.order = Math.max(this.order, order);
          if (!this.versions.some((version) => version.code === artifact.code)) this.append(artifact);
        }
    }
    if (!this.versions.some((version) => version.code === opened.code)) this.append(this.artifact);
    else this.versions = this.versions.map((version) => (version.code === opened.code ? this.artifact : version));
    this.unsubscribe = producer?.subscribe((updates) => {
      for (const update of updates) this.changed(update);
    });
  }

  private matches(artifact: Artifact) {
    return artifact.path === this.artifact.path && artifact.kind === this.artifact.kind;
  }
  private append(artifact: Artifact) {
    if (this.versions.length === 64) this.versions.shift();
    this.versions.push(artifact);
  }
  private changed(update: RowUpdate) {
    if (this.disposed || update.order <= this.order) return;
    const before = update.before ? toolArtifacts(update.before) : [];
    for (const next of toolArtifacts(update.tool)) {
      if (!this.matches(next) || before.some((old) => this.matches(old) && old.code === next.code)) continue;
      this.order = update.order;
      this.artifact = { ...next, identity: this.artifact.identity, revision: ++this.revision };
      const index = this.versions.findIndex((version) => version.code === next.code);
      if (index < 0) this.append(this.artifact);
      else this.versions = this.versions.map((version, at) => (at === index ? this.artifact : version));
    }
  }
  read(rows: readonly ArtifactSourceRow[]) {
    if (!this.unsubscribe && !this.disposed) {
      // Static/gallery snapshots have no producer. Inspect only their bounded tail; live clients
      // publish exact deltas, including updates to concurrent tools far above the visible tail.
      for (let index = Math.max(0, rows.length - 64); index < rows.length; index++) {
        const row = rows[index]!;
        if (this.recent.has(row)) continue;
        this.recent.add(row);
        for (const item of row.items ?? [])
          if (item.tool) this.changed({ id: row.id, version: row.version, order: row.at ?? 0, tool: item.tool });
      }
    }
    return { artifact: this.artifact, versions: this.versions };
  }
  dispose() {
    this.disposed = true;
    this.unsubscribe?.();
    this.unsubscribe = undefined;
  }
}
