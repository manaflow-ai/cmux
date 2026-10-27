// Follow canonical file identity, never a title or a filesystem read. Only the existing detector
// decides whether a completed tool recorded a complete document.
import type { AcpmuxRow } from "../model";
import { rowUpdates, type RowUpdate, type RowUpdates } from "../rowUpdates";
import type { Artifact } from "./artifactPreview";
import type { ArtifactSourceRow } from "./artifactVersions";
import { toolArtifacts } from "./artifactWrites";

export class ArtifactWrittenLive {
  private artifact: Artifact;
  private versions: Artifact[] = [];
  private order = -Infinity;
  private revision = 0;
  private toolId?: string;
  private unsubscribe?: () => void;
  private producer?: RowUpdates;
  private recent = new WeakSet<ArtifactSourceRow>();
  private disposed = false;

  constructor(opened: Artifact, rows: readonly ArtifactSourceRow[]) {
    this.artifact = { ...opened, identity: `file:${opened.path}`, revision: 0 };
    const producer = (this.producer = rowUpdates(rows));
    for (const row of rows) {
      this.recent.add(row);
      const order = producer?.orderOf(row as AcpmuxRow) ?? row.at ?? 0;
      for (const item of row.items ?? [])
        for (const artifact of item.tool ? toolArtifacts(item.tool) : []) {
          if (!this.matches(artifact)) continue;
          this.order = Math.max(this.order, producer?.artifactOrder(artifact) ?? order);
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
    if (this.disposed) return;
    const before = update.before ? toolArtifacts(update.before) : [];
    for (const next of toolArtifacts(update.tool)) {
      const order = this.producer?.artifactOrder(next) ?? update.order;
      if (order < this.order || (order === this.order && update.tool.id === this.toolId)) continue;
      if (!this.matches(next) || before.some((old) => this.matches(old) && old.code === next.code)) continue;
      this.order = order;
      this.toolId = update.tool.id;
      this.artifact = { ...next, identity: this.artifact.identity, revision: ++this.revision };
      const index = this.versions.findIndex((version) => version.code === next.code);
      if (index < 0) this.append(this.artifact);
      else this.versions = this.versions.map((version, at) => (at === index ? this.artifact : version));
    }
  }
  read(rows: readonly ArtifactSourceRow[]) {
    if (this.disposed) return { artifact: this.artifact, versions: this.versions };
    const producer = rowUpdates(rows);
    if (producer && producer !== this.producer) {
      // Reconnect can replace the client. Reconcile its current rows once, then subscribe to
      // every publication; a cached snapshot or old client's late response cannot bind us back.
      if (this.producer && producer.generation < this.producer.generation)
        return { artifact: this.artifact, versions: this.versions };
      this.unsubscribe?.();
      this.producer = producer;
      this.order = -Infinity;
      this.toolId = undefined;
      for (const row of rows)
        for (const item of row.items ?? [])
          if (item.tool)
            this.changed({
              id: row.id,
              version: row.version,
              order: producer.orderOf(row as AcpmuxRow),
              tool: item.tool,
            });
      this.unsubscribe = producer.subscribe((updates) => {
        for (const update of updates) this.changed(update);
      });
    }
    if (!producer && !this.producer) {
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
