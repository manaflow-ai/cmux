// CatalogRepo on Postgres (models_dev_snapshots, catalog_overrides, catalog_versions).

import { desc, eq, sql } from "drizzle-orm";

import { cloudDb } from "../../db/client";
import { catalogOverrides, catalogVersions, modelsDevSnapshots } from "../../db/schema";
import type { OverrideKind } from "./overrideRows";
import type { CatalogRepo, SnapshotRecord, VersionRecord } from "./publish";

type Db = ReturnType<typeof cloudDb>;

export function databaseCatalogRepo(db: () => Db = cloudDb): CatalogRepo {
  return {
    async newestSnapshot() {
      const [row] = await db().select().from(modelsDevSnapshots).orderBy(desc(modelsDevSnapshots.id)).limit(1);
      return row as SnapshotRecord | undefined;
    },
    async insertSnapshot({ contentHash, raw, fetchedAt }) {
      const inserted = await db()
        .insert(modelsDevSnapshots)
        .values({ contentHash, raw, fetchedAt })
        .onConflictDoNothing({ target: modelsDevSnapshots.contentHash })
        .returning();
      if (inserted[0]) return { snapshot: inserted[0] as SnapshotRecord, inserted: true };
      const [existing] = await db().select().from(modelsDevSnapshots).where(eq(modelsDevSnapshots.contentHash, contentHash)).limit(1);
      if (!existing) throw new Error("models_dev_snapshots: the conflicting row is gone");
      return { snapshot: existing as SnapshotRecord, inserted: false };
    },
    async listOverrides() {
      const rows = await db().select().from(catalogOverrides).orderBy(catalogOverrides.harnessId, catalogOverrides.kind, catalogOverrides.modelId);
      return rows.map((row) => ({
        id: row.id,
        kind: row.kind as OverrideKind,
        harnessId: row.harnessId,
        modelId: row.modelId,
        value: row.value as Record<string, unknown>,
        active: row.active,
        author: row.author,
        updatedAt: row.updatedAt,
      }));
    },
    async upsertOverride(row, author) {
      const [saved] = await db()
        .insert(catalogOverrides)
        .values({ kind: row.kind, harnessId: row.harnessId, modelId: row.modelId, value: row.value, active: row.active, author })
        .onConflictDoUpdate({
          target: [catalogOverrides.kind, catalogOverrides.harnessId, catalogOverrides.modelId],
          set: { value: row.value, active: row.active, author, updatedAt: sql`now()` },
        })
        .returning({ id: catalogOverrides.id });
      if (!saved) throw new Error("catalog_overrides: the upsert returned no row");
      return saved;
    },
    async newestVersion() {
      const [row] = await db().select().from(catalogVersions).orderBy(desc(catalogVersions.version)).limit(1);
      return row as VersionRecord | undefined;
    },
    async insertVersion(input) {
      const [row] = await db().insert(catalogVersions).values(input).returning();
      if (!row) throw new Error("catalog_versions: the insert returned no row");
      return row as VersionRecord;
    },
  };
}
