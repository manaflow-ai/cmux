// Where the served catalog comes from, newest first:
//   1. this instance's memory (re-checked against the shared cache every 5 min);
//   2. the Vercel Runtime Cache, shared by every instance (30-day entries);
//   3. the snapshot checked into the repo (web/data/model-catalog/snapshot.json).
// A request never waits for models.dev. When the copy in use is older than
// 6 h, one background refresh per instance fetches models.dev, projects it
// through overrides.ts, and keeps and stores the result only when it passes
// validation. A failed refresh (outage, format break) keeps the last good
// copy and waits 5 min before the next try.

import { createHash } from "node:crypto";

import { getCache } from "@vercel/functions";

import snapshotJson from "../../data/model-catalog/snapshot.json";
import { projectCatalog } from "./project";
import { validateCatalog } from "./schema";
import type { ModelCatalog } from "./types";
import { fetchFeed } from "./upstream";

export const REFRESH_AFTER_MS = 6 * 60 * 60 * 1000;
export const FAILURE_BACKOFF_MS = 5 * 60 * 1000;
export const MEMORY_RECHECK_MS = 5 * 60 * 1000;
const CACHE_TTL_SECONDS = 30 * 24 * 60 * 60;
const CACHE_READ_TIMEOUT_MS = 300;
const CACHE_WRITE_TIMEOUT_MS = 2_000;

export interface BuiltCatalog {
  catalog: ModelCatalog;
  /** The serialized body and its strong ETag. */
  body: string;
  etag: string;
}

export interface CatalogStoreDeps {
  snapshot: ModelCatalog;
  readShared: () => Promise<unknown>;
  writeShared: (catalog: ModelCatalog) => Promise<void>;
  /** Fetches models.dev and projects it; throws on any failure. */
  loadLive: (now: Date) => Promise<ModelCatalog>;
  now: () => number;
}

/** Keeps a background task alive after the response (Next `after`). */
export type Defer = (task: Promise<unknown>) => void;

export function packCatalog(catalog: ModelCatalog): BuiltCatalog {
  const body = JSON.stringify(catalog);
  const etag = `"${createHash("sha256").update(body).digest("base64url")}"`;
  return { catalog, body, etag };
}

function tryValidate(value: unknown): ModelCatalog | undefined {
  try {
    return validateCatalog(value);
  } catch {
    return undefined;
  }
}

/** One instance's state. Tests make their own; the route uses `catalogStore()`. */
export class CatalogStore {
  private memory?: { built: BuiltCatalog; checkedAt: number };
  private refreshing?: Promise<void>;
  private failedAt = Number.NEGATIVE_INFINITY;
  private snapshotBuilt?: BuiltCatalog;

  constructor(private readonly deps: CatalogStoreDeps) {}

  snapshotCatalog(): BuiltCatalog {
    this.snapshotBuilt ??= packCatalog(validateCatalog(this.deps.snapshot));
    return this.snapshotBuilt;
  }

  private async readShared(): Promise<BuiltCatalog | undefined> {
    try {
      const catalog = tryValidate(await this.deps.readShared());
      return catalog ? packCatalog(catalog) : undefined;
    } catch {
      return undefined;
    }
  }

  private remember(built: BuiltCatalog): void {
    const current = this.memory?.built;
    // Never replace a live copy with an older one (a slow cache read after a refresh).
    const older = current?.catalog.source === "live"
      && Date.parse(current.catalog.generatedAt) > Date.parse(built.catalog.generatedAt);
    this.memory = { built: older && current ? current : built, checkedAt: this.deps.now() };
  }

  /** The catalog to serve now. Never waits for models.dev. */
  async current(defer: Defer): Promise<BuiltCatalog> {
    const now = this.deps.now();
    if (!this.memory || now - this.memory.checkedAt >= MEMORY_RECHECK_MS) {
      const shared = await this.readShared();
      this.remember(shared ?? this.memory?.built ?? this.snapshotCatalog());
    }
    const built = (this.memory ?? { built: this.snapshotCatalog() }).built;
    const stale = built.catalog.source !== "live" || now - Date.parse(built.catalog.generatedAt) >= REFRESH_AFTER_MS;
    if (stale) this.scheduleRefresh(defer);
    return built;
  }

  /** Starts one background refresh unless one runs or the last one failed recently. */
  scheduleRefresh(defer: Defer): void {
    if (this.refreshing || this.deps.now() - this.failedAt < FAILURE_BACKOFF_MS) return;
    const task = this.refresh().finally(() => {
      this.refreshing = undefined;
    });
    this.refreshing = task;
    defer(task);
  }

  /** Fetches and projects models.dev; keeps and stores the result only when it validates. Never throws. */
  async refresh(): Promise<void> {
    try {
      const catalog = validateCatalog(await this.deps.loadLive(new Date(this.deps.now())));
      this.remember(packCatalog(catalog));
      await this.deps.writeShared(catalog).catch(() => undefined);
    } catch (error) {
      this.failedAt = this.deps.now();
      // The last good copy keeps serving; this line is the outage signal in the logs.
      console.warn("model catalog: models.dev refresh failed", error instanceof Error ? error.message : String(error));
    }
  }
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

// The key names the overrides, so a deploy that changes them does not serve the old projection.
const OVERRIDES_KEY = createHash("sha256")
  .update(JSON.stringify((snapshotJson as { harnesses?: unknown }).harnesses ?? []))
  .digest("hex")
  .slice(0, 16);
const CACHE_KEY = `v1:${process.env.VERCEL_DEPLOYMENT_ID ?? OVERRIDES_KEY}`;
const CACHE_OPTIONS = { namespace: "cmux-model-catalog", keyHashFunction: (key: string) => key };

export function runtimeCacheDeps(): Pick<CatalogStoreDeps, "readShared" | "writeShared"> {
  const disabled = process.env.NODE_ENV === "test";
  return {
    readShared: async () => (disabled ? undefined : await withDeadline(getCache(CACHE_OPTIONS).get(CACHE_KEY), CACHE_READ_TIMEOUT_MS)),
    writeShared: async (catalog) => {
      if (disabled) return;
      await withDeadline(
        getCache(CACHE_OPTIONS).set(CACHE_KEY, catalog, { name: "model-catalog", ttl: CACHE_TTL_SECONDS }),
        CACHE_WRITE_TIMEOUT_MS,
      );
    },
  };
}

export const bundledSnapshot = (): ModelCatalog => validateCatalog(snapshotJson);

let defaultStore: CatalogStore | undefined;

/** The process-wide store the route uses. */
export function catalogStore(): CatalogStore {
  defaultStore ??= new CatalogStore({
    snapshot: bundledSnapshot(),
    ...runtimeCacheDeps(),
    loadLive: async (now) => projectCatalog(await fetchFeed(), now),
    now: () => Date.now(),
  });
  return defaultStore;
}
