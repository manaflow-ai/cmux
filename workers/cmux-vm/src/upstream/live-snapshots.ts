/**
 * The live provider snapshot client (see src/upstream/snapshots.ts for the
 * interface). Imported only from src/upstream/, src/proofs/ and src/index.ts.
 */
import { makeSnapshotCaptureClient } from "./snapshot-capture.ts";
import { Effect, Layer, Redacted, Schema } from "effect";
import type { Environment } from "../policy.ts";
import { UpstreamError } from "./client.ts";
import { makeUpstreamHttp, proofSegment } from "./live-http.ts";
import type { UpstreamConfig } from "./live.ts";
import { type CreatedSnapshot, UpstreamSnapshot, UpstreamSnapshots, type UpstreamSnapshotsService } from "./snapshots.ts";

const decodeAs =
  <A, I>(schema: Schema.Schema<A, I>, operation: string) =>
  (body: unknown): Effect.Effect<A, UpstreamError> =>
    Schema.decodeUnknown(schema)(body).pipe(Effect.mapError(() => new UpstreamError({ operation, status: null })));

export function makeUpstreamSnapshots(config: UpstreamConfig): UpstreamSnapshotsService {
  const http = makeUpstreamHttp(config);
  const created = new WeakSet<CreatedSnapshot>();

  return {
    ...makeSnapshotCaptureClient(config, http, (result) => { created.add(result); return result; }),
    discardCreatedSnapshot: (result) =>
      created.has(result)
        ? http
            .json("discardCreatedSnapshot", "DELETE", `/v5/snapshots/${encodeURIComponent(result.upstreamId)}`)
            .pipe(Effect.asVoid)
        : Effect.fail(new UpstreamError({ operation: "discardCreatedSnapshot", status: null })),
    getSnapshot: (_snapshot, { owns }) =>
      http
        .json("getSnapshot", "GET", `/v5/snapshots/${proofSegment(owns)}`)
        .pipe(Effect.flatMap(decodeAs(UpstreamSnapshot, "getSnapshot"))),
    deleteSnapshot: (_snapshot, { owns }) =>
      http.json("deleteSnapshot", "DELETE", `/v5/snapshots/${proofSegment(owns)}`).pipe(Effect.asVoid),
  };
}

export const upstreamSnapshotsLayer = (config: { readonly baseUrl: string; readonly apiKey: string; readonly environment: Environment }): Layer.Layer<UpstreamSnapshots> =>
  Layer.succeed(UpstreamSnapshots, makeUpstreamSnapshots({ baseUrl: config.baseUrl, apiKey: Redacted.make(config.apiKey), environment: config.environment }));
