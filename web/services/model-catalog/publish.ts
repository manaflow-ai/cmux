// The catalog pipeline behind GET /api/models/v1:
//   ingest:  models.dev -> a new models_dev_snapshots row only when its content hash changes;
//   publish: newest snapshot + active overrides -> projectCatalog -> strict check -> a new
//            catalog_versions row only when the served body's hash changes.
// The route only reads the newest published version; nothing is built per request.

import { createHash } from "node:crypto";

import { METADATA_PROVIDERS } from "./overrides";
import { overridesFromRows, type OverrideRow } from "./overrideRows";
import { projectCatalog } from "./project";
import { validateCatalog } from "./schema";
import type { ModelCatalog } from "./types";

export interface SnapshotRecord {
  id: number;
  contentHash: string;
  fetchedAt: Date;
  raw: unknown;
}

export interface VersionRecord {
  version: number;
  contentHash: string;
  catalog: unknown;
  publishedAt: Date;
  publishedBy: string;
  sourceSnapshotId: number | null;
}

/** The three tables, behind an interface so the pipeline is tested without a database. */
export interface CatalogRepo {
  newestSnapshot(): Promise<SnapshotRecord | undefined>;
  /** Inserts unless a row with this hash exists; returns the row (new or existing) and whether it is new. */
  insertSnapshot(input: { contentHash: string; raw: unknown; fetchedAt: Date }): Promise<{ snapshot: SnapshotRecord; inserted: boolean }>;
  listOverrides(): Promise<(OverrideRow & { id: string; author: string; updatedAt: Date })[]>;
  /** Creates or replaces the row for (kind, harnessId, modelId). */
  upsertOverride(row: OverrideRow, author: string): Promise<{ id: string }>;
  newestVersion(): Promise<VersionRecord | undefined>;
  insertVersion(input: Omit<VersionRecord, "version" | "publishedAt">): Promise<VersionRecord>;
}

/** JSON with object keys sorted at every level: the same data always gives the same bytes. */
export function canonicalJson(value: unknown): string {
  const sort = (input: unknown): unknown => {
    if (Array.isArray(input)) return input.map(sort);
    if (input && typeof input === "object") {
      return Object.fromEntries(Object.keys(input).sort().map((key) => [key, sort((input as Record<string, unknown>)[key])]));
    }
    return input;
  };
  return JSON.stringify(sort(value));
}

export function contentHash(body: string): string {
  return createHash("sha256").update(body).digest("base64url");
}

/** The providers the overrides read: each harness's sources plus the metadata providers. */
export function feedProviders(rows: readonly OverrideRow[]): string[] {
  const sources = overridesFromRows(rows).flatMap((harness) => (harness.sources ?? []).map((source) => source.provider));
  return [...new Set([...METADATA_PROVIDERS, ...sources])].sort();
}

/** The models.dev document reduced to `providers` (the full file is about 5 MB). */
export function reduceFeed(feed: unknown, providers: readonly string[]): Record<string, unknown> {
  if (!feed || typeof feed !== "object" || Array.isArray(feed)) throw new Error("models.dev returned a non-object document");
  const kept = Object.fromEntries(providers.filter((id) => id in feed).map((id) => [id, (feed as Record<string, unknown>)[id]]));
  if (Object.keys(kept).length === 0) throw new Error("models.dev named none of the curated providers");
  return kept;
}

/** Stores the feed as a new snapshot when its content changed. */
export async function ingestFeed(repo: CatalogRepo, feed: unknown, now: Date): Promise<{ snapshot: SnapshotRecord; inserted: boolean }> {
  const raw = reduceFeed(feed, feedProviders(await repo.listOverrides()));
  return repo.insertSnapshot({ contentHash: contentHash(canonicalJson(raw)), raw, fetchedAt: now });
}

export type PublishResult =
  | { ok: true; published: boolean; version: VersionRecord }
  | { ok: false; error: string };

/** Builds the catalog from the newest snapshot and the active overrides; publishes it when it changed. */
export async function publishCatalog(repo: CatalogRepo, publishedBy: string): Promise<PublishResult> {
  const snapshot = await repo.newestSnapshot();
  if (!snapshot) return { ok: false, error: "no models.dev snapshot yet" };
  let catalog: ModelCatalog;
  try {
    const overrides = overridesFromRows(await repo.listOverrides());
    // generatedAt is the snapshot's fetch time, so the body changes only when the data does.
    catalog = validateCatalog(JSON.parse(JSON.stringify(projectCatalog(snapshot.raw, snapshot.fetchedAt, overrides, "live"))));
  } catch (error) {
    return { ok: false, error: error instanceof Error ? error.message : String(error) };
  }
  const hash = contentHash(canonicalJson(catalog));
  const newest = await repo.newestVersion();
  if (newest?.contentHash === hash) return { ok: true, published: false, version: newest };
  const version = await repo.insertVersion({ contentHash: hash, catalog, publishedBy, sourceSnapshotId: snapshot.id });
  return { ok: true, published: true, version };
}

/** An in-memory CatalogRepo (tests and offline tools). */
export function memoryCatalogRepo(seed: readonly OverrideRow[] = []): CatalogRepo & { snapshots: SnapshotRecord[]; versions: VersionRecord[] } {
  const snapshots: SnapshotRecord[] = [];
  const versions: VersionRecord[] = [];
  const overrides = seed.map((row, index) => ({ ...row, id: `seed-${index}`, author: "seed", updatedAt: new Date(0) }));
  const key = (row: OverrideRow) => `${row.kind}\u0000${row.harnessId}\u0000${row.modelId ?? ""}`;
  return {
    snapshots,
    versions,
    newestSnapshot: async () => snapshots.at(-1),
    insertSnapshot: async ({ contentHash: hash, raw, fetchedAt }) => {
      const existing = snapshots.find((snapshot) => snapshot.contentHash === hash);
      if (existing) return { snapshot: existing, inserted: false };
      const snapshot = { id: snapshots.length + 1, contentHash: hash, raw, fetchedAt };
      snapshots.push(snapshot);
      return { snapshot, inserted: true };
    },
    listOverrides: async () => overrides.map((row) => ({ ...row })),
    upsertOverride: async (row, author) => {
      const index = overrides.findIndex((existing) => key(existing) === key(row));
      const next = { ...row, id: index >= 0 ? overrides[index]!.id : `row-${overrides.length}`, author, updatedAt: new Date() };
      if (index >= 0) overrides[index] = next;
      else overrides.push(next);
      return { id: next.id };
    },
    newestVersion: async () => versions.at(-1),
    insertVersion: async (input) => {
      const version = { ...input, version: versions.length + 1, publishedAt: new Date() };
      versions.push(version);
      return version;
    },
  };
}
