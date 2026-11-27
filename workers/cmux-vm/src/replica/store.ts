/**
 * The paused-read replica (cmuxterm-hq RFD 0144 piece 2) as an Effect service: one Durable Object per VM in the
 * Worker, an in-process map in tests. Keys are public VM ids; the store never sees a provider id.
 */
import { Context, Data, Effect, Layer, Schema } from "effect";
import type { PausedReplicaObject } from "./durable-object.ts";
import { searchFiles, type ReplicaFile, type ReplicaMeta, type SearchMatch } from "./match.ts";

/** The replica store could not be reached; a search then reads the disk instead. */
export class ReplicaUnavailable extends Data.TaggedError("ReplicaUnavailable")<{ readonly cause: unknown }> {}

export interface ReplicaStoreService {
  readonly replace: (vmId: string, meta: ReplicaMeta, files: ReadonlyArray<ReplicaFile>) => Effect.Effect<void, ReplicaUnavailable>;
  readonly meta: (vmId: string) => Effect.Effect<ReplicaMeta | null, ReplicaUnavailable>;
  readonly search: (vmId: string, root: string, query: string, limit: number) => Effect.Effect<{ matches: SearchMatch[]; scanned: number }, ReplicaUnavailable>;
  readonly drop: (vmId: string) => Effect.Effect<void, ReplicaUnavailable>;
}

export class ReplicaStore extends Context.Tag("cmux-vm/ReplicaStore")<ReplicaStore, ReplicaStoreService>() {}

const MetaJson = Schema.parseJson(Schema.Struct({
  root: Schema.String, marker: Schema.String, complete: Schema.Boolean, files: Schema.Number, bytes: Schema.Number,
  truncated: Schema.Number, seededAtMs: Schema.Number,
}));
const SearchJson = Schema.parseJson(Schema.Struct({
  matches: Schema.Array(Schema.Struct({ path: Schema.String, line: Schema.Number, text: Schema.String })),
  scanned: Schema.Number,
}));
const decode = <A, I>(schema: Schema.Schema<A, I>) => (json: string) =>
  Schema.decodeUnknown(schema)(json).pipe(Effect.mapError((cause) => new ReplicaUnavailable({ cause })));

const call = <A>(run: () => Promise<A> | A) => Effect.tryPromise({ try: async () => run(), catch: (cause) => new ReplicaUnavailable({ cause }) });

export const durableObjectReplicaLayer = (namespace: DurableObjectNamespace<PausedReplicaObject>): Layer.Layer<ReplicaStore> => {
  const stub = (vmId: string) => namespace.get(namespace.idFromName(vmId));
  return Layer.succeed(ReplicaStore, {
    replace: (vmId, meta, files) => call(() => stub(vmId).replace(meta, files)),
    meta: (vmId) =>
      call(async (): Promise<string | null> => stub(vmId).meta()).pipe(Effect.flatMap((json) => (json === null ? Effect.succeed(null) : decode(MetaJson)(json)))),
    search: (vmId, root, query, limit) =>
      call(async (): Promise<string> => stub(vmId).search(root, query, limit)).pipe(
        Effect.flatMap(decode(SearchJson)),
        Effect.map(({ matches, scanned }) => ({ matches: [...matches], scanned })),
      ),
    drop: (vmId) => call(() => stub(vmId).drop()),
  });
};

/** The same store in process, for tests; `seeds` lets a test read or age what was stored. */
export const memoryReplicaLayer = (seeds = new Map<string, { meta: ReplicaMeta; files: ReadonlyArray<ReplicaFile> }>()): Layer.Layer<ReplicaStore> =>
  Layer.succeed(ReplicaStore, {
    replace: (vmId, meta, files) => Effect.sync(() => void seeds.set(vmId, { meta, files: [...files] })),
    meta: (vmId) => Effect.sync(() => seeds.get(vmId)?.meta ?? null),
    search: (vmId, root, query, limit) => Effect.sync(() => searchFiles(seeds.get(vmId)?.files ?? [], root, query, limit)),
    drop: (vmId) => Effect.sync(() => void seeds.delete(vmId)),
  });
