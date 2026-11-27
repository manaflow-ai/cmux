// What GET /api/models/v1 serves: the newest published catalog version
// (catalog_versions), read at most once a minute per instance, else the
// snapshot checked into the repo (web/data/model-catalog/snapshot.json) when
// no version is published yet or the database cannot be read. Building a
// catalog happens only in the publish step (publish.ts), never per request.

import snapshotJson from "../../data/model-catalog/snapshot.json";
import { canonicalJson, contentHash, type CatalogRepo } from "./publish";
import { databaseCatalogRepo } from "./repo";
import { validateCatalog } from "./schema";
import type { ModelCatalog } from "./types";

export const RECHECK_MS = 60 * 1000;

export interface BuiltCatalog {
  catalog: ModelCatalog;
  /** The canonical serialized body and its strong ETag (the version's content hash). */
  body: string;
  etag: string;
  /** The published version, or null for the bundled snapshot. */
  version: number | null;
}

export function packCatalog(catalog: ModelCatalog, version: number | null): BuiltCatalog {
  const body = canonicalJson(catalog);
  return { catalog, body, etag: `"${contentHash(body)}"`, version };
}

export const bundledSnapshot = (): ModelCatalog => validateCatalog(snapshotJson);

/** One instance's cache of the newest version. */
export class CatalogStore {
  private memory?: { built: BuiltCatalog; checkedAt: number };
  private snapshotBuilt?: BuiltCatalog;

  constructor(
    private readonly repo: Pick<CatalogRepo, "newestVersion">,
    private readonly snapshot: ModelCatalog,
    private readonly now: () => number = Date.now,
  ) {}

  snapshotCatalog(): BuiltCatalog {
    this.snapshotBuilt ??= packCatalog(validateCatalog(this.snapshot), null);
    return this.snapshotBuilt;
  }

  private async readNewest(): Promise<BuiltCatalog | undefined> {
    try {
      const newest = await this.repo.newestVersion();
      if (!newest) return undefined;
      if (this.memory?.built.version === newest.version) return this.memory.built;
      return packCatalog(validateCatalog(newest.catalog), newest.version);
    } catch (error) {
      console.warn("model catalog: the newest version could not be read", error instanceof Error ? error.message : String(error));
      return undefined;
    }
  }

  async current(): Promise<BuiltCatalog> {
    const now = this.now();
    if (!this.memory || now - this.memory.checkedAt >= RECHECK_MS) {
      const newest = await this.readNewest();
      this.memory = { built: newest ?? this.memory?.built ?? this.snapshotCatalog(), checkedAt: now };
    }
    return this.memory.built;
  }
}

let defaultStore: CatalogStore | undefined;

/** The process-wide store the route uses. */
export function catalogStore(): CatalogStore {
  defaultStore ??= new CatalogStore(databaseCatalogRepo(), bundledSnapshot());
  return defaultStore;
}
