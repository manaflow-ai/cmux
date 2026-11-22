/**
 * The live provider snapshot client (see src/upstream/snapshots.ts for the
 * interface). Imported only from src/upstream/, src/proofs/ and src/index.ts.
 */
import { Effect, Layer, Redacted, Schema } from "effect";
import { UpstreamId } from "../lib/ids.ts";
import type { Environment } from "../policy.ts";
import { UpstreamError } from "./client.ts";
import { makeUpstreamHttp, proofSegment } from "./live-http.ts";
import type { UpstreamConfig } from "./live.ts";
import { upstreamName } from "./naming.ts";
import { type CreatedSnapshot, UpstreamSnapshot, UpstreamSnapshots, type UpstreamSnapshotsService } from "./snapshots.ts";

const CREATE_TIMEOUT_MS = 120_000;

const SnapshotCreated = Schema.Struct({ snapshotId: UpstreamId, snapshot: UpstreamSnapshot });

const decodeAs =
  <A, I>(schema: Schema.Schema<A, I>, operation: string) =>
  (body: unknown): Effect.Effect<A, UpstreamError> =>
    Schema.decodeUnknown(schema)(body).pipe(Effect.mapError(() => new UpstreamError({ operation, status: null })));

export function makeUpstreamSnapshots(config: UpstreamConfig): UpstreamSnapshotsService {
  const http = makeUpstreamHttp(config);
  const created = new WeakSet<CreatedSnapshot>();

  return {
    createSnapshot: (_vm, { owns }, options) =>
      http
        .json(
          "createSnapshot",
          "POST",
          `/v5/vms/${proofSegment(owns)}/snapshot`,
          {
            displayName: upstreamName(config.environment, options.tenantId, options.snapshotId),
            ...(options.ttlSeconds === undefined ? {} : { ttlSeconds: options.ttlSeconds }),
            ...(options.autoDeleteSeconds === undefined ? {} : { autoDeleteSeconds: options.autoDeleteSeconds }),
          },
          // Capturing memory and disk can take far longer than a read.
          { timeoutMs: CREATE_TIMEOUT_MS },
        )
        .pipe(
          Effect.flatMap(decodeAs(SnapshotCreated, "createSnapshot")),
          Effect.map((body) => {
            const result: CreatedSnapshot = Object.freeze({ upstreamId: body.snapshotId, snapshot: body.snapshot });
            created.add(result);
            return result;
          }),
        ),
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
