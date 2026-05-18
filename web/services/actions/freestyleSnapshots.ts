import { Freestyle } from "freestyle";
import * as Data from "effect/Data";
import * as Effect from "effect/Effect";

export type FreestyleActionSnapshot = {
  readonly id: string;
  readonly name: string;
  readonly createdAt: string;
};

type FreestyleSnapshotRecord = {
  readonly snapshotId?: string;
  readonly id?: string;
  readonly name?: string;
  readonly state?: string;
  readonly status?: string;
  readonly deleted?: boolean;
  readonly failureReason?: string;
  readonly createdAt?: string;
};

type FreestyleSnapshotListResponse = {
  readonly snapshots?: readonly FreestyleSnapshotRecord[] | null;
};

const DEFAULT_TIMEOUT_MS = 60_000;

export class FreestyleActionSnapshotLookupError extends Data.TaggedError("FreestyleActionSnapshotLookupError")<{
  readonly kind: "request" | "http" | "response";
  readonly status?: number;
  readonly cause?: unknown;
}> {}

export function findFreestyleActionSnapshotByName(
  name: string,
): Effect.Effect<FreestyleActionSnapshot | null, FreestyleActionSnapshotLookupError> {
  return Effect.gen(function* () {
    const fs = yield* Effect.try({
      try: () =>
        new Freestyle({
          apiKey: process.env.FREESTYLE_API_KEY ?? "missing-freestyle-api-key",
          fetch: fetchWithTimeout(DEFAULT_TIMEOUT_MS),
        }),
      catch: (cause) => new FreestyleActionSnapshotLookupError({ kind: "request", cause }),
    });
    const response = yield* Effect.tryPromise({
      try: () => fs.fetch(freestyleSnapshotListURL(), { method: "GET" }),
      catch: (cause) => new FreestyleActionSnapshotLookupError({ kind: "request", cause }),
    });
    if (!response.ok) {
      return yield* Effect.fail(new FreestyleActionSnapshotLookupError({
        kind: "http",
        status: response.status,
      }));
    }
    const json = yield* Effect.tryPromise({
      try: () => response.json() as Promise<FreestyleSnapshotListResponse>,
      catch: (cause) => new FreestyleActionSnapshotLookupError({ kind: "response", cause }),
    });
    return selectReusableSnapshot(name, json);
  });
}

function selectReusableSnapshot(
  name: string,
  json: FreestyleSnapshotListResponse,
): FreestyleActionSnapshot | null {
  const matches = (json.snapshots ?? [])
    .filter((snapshot) => snapshot.name === name && snapshot.deleted !== true)
    .sort((a, b) => (b.createdAt ?? "").localeCompare(a.createdAt ?? ""));
  const latest = matches.find(isReusableSnapshot);
  if (!latest) return null;
  const id = latest.snapshotId ?? latest.id;
  if (!id || !latest.name || !latest.createdAt) return null;
  return { id, name: latest.name, createdAt: latest.createdAt };
}

function isReusableSnapshot(snapshot: FreestyleSnapshotRecord): boolean {
  const state = (snapshot.state ?? snapshot.status ?? "").trim().toLowerCase();
  if (!state) return !snapshot.failureReason;
  return ["ready", "completed", "complete", "succeeded", "success", "active"].includes(state);
}

function freestyleSnapshotListURL(): string {
  const base = (process.env.FREESTYLE_API_URL ?? "https://api.freestyle.sh").replace(/\/+$/, "");
  const url = new URL("/v1/vms/snapshots", base);
  url.searchParams.set("includeDeleted", "false");
  url.searchParams.set("includeFailed", "true");
  return url.toString();
}

export function fetchWithTimeout(timeoutMs: number): typeof fetch {
  return async (input, init) => {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), timeoutMs);
    const signal = init?.signal ? AbortSignal.any([init.signal, controller.signal]) : controller.signal;
    try {
      return await fetch(input, {
        ...(init ?? {}),
        signal,
      });
    } finally {
      clearTimeout(timeout);
    }
  };
}
