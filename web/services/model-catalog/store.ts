// Where the catalog's models.dev data comes from, newest first:
//   1. this instance's memory (re-checked against the shared cache every 5 min);
//   2. the Vercel Runtime Cache, shared by every instance (30-day entries);
//   3. the snapshot checked into the repo (web/data/model-catalog/models-dev-snapshot.json).
// A request never waits for models.dev. When the copy in use is older than
// 6 h, one background refresh per instance fetches models.dev, builds the
// catalog from it, and stores it only when that build passes validation. A
// failed refresh (outage, format break) keeps the last good copy and waits
// 5 min before the next try.

import { createHash } from "node:crypto";

import { getCache } from "@vercel/functions";

import snapshotJson from "../../data/model-catalog/models-dev-snapshot.json";
import overridesJson from "../../data/model-catalog/overrides.json";
import { buildCatalog } from "./build";
import { curatedProviderIds, validateOverrides, type CatalogOverrides } from "./overrides";
import type { ModelCatalog } from "./schema";
import { fetchUpstream, readStoredSubset, type UpstreamSubset } from "./upstream";

export const REFRESH_AFTER_MS = 6 * 60 * 60 * 1000;
export const FAILURE_BACKOFF_MS = 5 * 60 * 1000;
export const MEMORY_RECHECK_MS = 5 * 60 * 1000;
const CACHE_TTL_SECONDS = 30 * 24 * 60 * 60;
const CACHE_READ_TIMEOUT_MS = 300;
const CACHE_WRITE_TIMEOUT_MS = 2_000;

export type CatalogSource = "live" | "snapshot";

export interface BuiltCatalog {
  catalog: ModelCatalog;
  /** The serialized body and its strong ETag. */
  body: string;
  etag: string;
  source: CatalogSource;
  fetchedAt: string;
}

export interface CatalogStoreDeps {
  overrides: CatalogOverrides;
  snapshot: UpstreamSubset;
  readShared: () => Promise<unknown>;
  writeShared: (subset: UpstreamSubset) => Promise<void>;
  fetchUpstream: (providerIds: readonly string[]) => Promise<UpstreamSubset>;
  now: () => number;
}

/** Keeps a background task alive after the response (Next `after`). */
export type Defer = (task: Promise<unknown>) => void;

export function packCatalog(catalog: ModelCatalog, source: CatalogSource, fetchedAt: string): BuiltCatalog {
  const body = JSON.stringify(catalog);
  const etag = `"${createHash("sha256").update(body).digest("base64url")}"`;
  return { catalog, body, etag, source, fetchedAt };
}

/** One instance's state. Tests make their own; the route uses `defaultStore`. */
export class CatalogStore {
  private memory?: { built: BuiltCatalog; checkedAt: number };
  private refreshing?: Promise<void>;
  private failedAt = Number.NEGATIVE_INFINITY;
  private snapshotBuilt?: BuiltCatalog;

  constructor(private readonly deps: CatalogStoreDeps) {}

  /** The catalog built from the bundled snapshot. It must always build; tests pin that. */
  snapshotCatalog(): BuiltCatalog {
    this.snapshotBuilt ??= packCatalog(
      buildCatalog(this.deps.snapshot, this.deps.overrides),
      "snapshot",
      this.deps.snapshot.fetchedAt,
    );
    return this.snapshotBuilt;
  }

  /** Builds from a fetched or stored copy; undefined when that copy does not build. */
  private tryBuild(subset: UpstreamSubset): BuiltCatalog | undefined {
    try {
      return packCatalog(buildCatalog(subset, this.deps.overrides), "live", subset.fetchedAt);
    } catch {
      return undefined;
    }
  }

  private async readShared(): Promise<BuiltCatalog | undefined> {
    let stored: unknown;
    try {
      stored = await this.deps.readShared();
    } catch {
      return undefined;
    }
    const subset = readStoredSubset(stored);
    return subset ? this.tryBuild(subset) : undefined;
  }

  private remember(built: BuiltCatalog): void {
    const current = this.memory?.built;
    // Never replace a copy with an older one (a slow cache read after a refresh).
    if (current && current.source === "live" && Date.parse(current.fetchedAt) > Date.parse(built.fetchedAt)) {
      this.memory = { built: current, checkedAt: this.deps.now() };
      return;
    }
    this.memory = { built, checkedAt: this.deps.now() };
  }

  /** The catalog to serve now. Never waits for models.dev. */
  async current(defer: Defer): Promise<BuiltCatalog> {
    const now = this.deps.now();
    if (!this.memory || now - this.memory.checkedAt >= MEMORY_RECHECK_MS) {
      const shared = await this.readShared();
      this.remember(shared ?? this.memory?.built ?? this.snapshotCatalog());
    }
    const built = this.memory!.built;
    if (now - Date.parse(built.fetchedAt) >= REFRESH_AFTER_MS) this.scheduleRefresh(defer);
    return built;
  }

  /** Starts one background refresh unless one runs or the last one failed recently. */
  scheduleRefresh(defer: Defer): void {
    const now = this.deps.now();
    if (this.refreshing || now - this.failedAt < FAILURE_BACKOFF_MS) return;
    const task = this.refresh().finally(() => {
      this.refreshing = undefined;
    });
    this.refreshing = task;
    defer(task);
  }

  /** Fetches models.dev; keeps and stores the result only when it builds. Never throws. */
  async refresh(): Promise<void> {
    try {
      const subset = await this.deps.fetchUpstream(curatedProviderIds(this.deps.overrides));
      const built = this.tryBuild(subset);
      if (!built) throw new Error("the models.dev data did not build a valid catalog");
      this.remember(built);
      await this.deps.writeShared(subset).catch(() => undefined);
    } catch (error) {
      this.failedAt = this.deps.now();
      // The last good copy keeps serving; this line is the outage signal in the logs.
      console.warn("model catalog: models.dev refresh failed", error instanceof Error ? error.message : String(error));
    }
  }
}

function sharedCacheKey(overrides: CatalogOverrides): string {
  const providers = createHash("sha256").update(curatedProviderIds(overrides).join(",")).digest("hex").slice(0, 16);
  return `v1:${providers}`;
}

async function withDeadline<T>(operation: Promise<T>, timeoutMs: number): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error("runtime cache deadline")), timeoutMs);
  });
  try {
    return await Promise.race([operation, deadline]);
  } finally {
    clearTimeout(timer);
  }
}

const CACHE_OPTIONS = { namespace: "cmux-model-catalog", keyHashFunction: (key: string) => key };

export function runtimeCacheDeps(overrides: CatalogOverrides): Pick<CatalogStoreDeps, "readShared" | "writeShared"> {
  const key = sharedCacheKey(overrides);
  const disabled = process.env.NODE_ENV === "test";
  return {
    readShared: async () => (disabled ? undefined : await withDeadline(getCache(CACHE_OPTIONS).get(key), CACHE_READ_TIMEOUT_MS)),
    writeShared: async (subset) => {
      if (disabled) return;
      await withDeadline(
        getCache(CACHE_OPTIONS).set(key, subset, { name: "models-dev-subset", ttl: CACHE_TTL_SECONDS }),
        CACHE_WRITE_TIMEOUT_MS,
      );
    },
  };
}

export const curatedOverrides: CatalogOverrides = validateOverrides(overridesJson);

export function bundledSnapshot(): UpstreamSubset {
  const subset = readStoredSubset(snapshotJson);
  if (!subset) throw new Error("web/data/model-catalog/models-dev-snapshot.json is not a valid snapshot");
  return subset;
}

let defaultStore: CatalogStore | undefined;

/** The process-wide store the route uses. */
export function catalogStore(): CatalogStore {
  defaultStore ??= new CatalogStore({
    overrides: curatedOverrides,
    snapshot: bundledSnapshot(),
    ...runtimeCacheDeps(curatedOverrides),
    fetchUpstream: (providerIds) => fetchUpstream(providerIds),
    now: () => Date.now(),
  });
  return defaultStore;
}
