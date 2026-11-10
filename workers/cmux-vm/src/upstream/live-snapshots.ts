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
import { classicImportDigest, type ClassicImportRequest } from "../domain/classic-import.ts";
import { UpstreamId } from "../lib/ids.ts";

/** The fields of a provider snapshot a classic import reads: its id and the VM it was taken from. */
const ClassicImportSnapshot = Schema.Struct({ ...UpstreamSnapshot.fields, id: UpstreamId, sourceVmId: Schema.String });
const ClassicImportCreated = Schema.Struct({ snapshotId: UpstreamId, snapshot: ClassicImportSnapshot });

const decodeAs =
  <A, I>(schema: Schema.Schema<A, I>, operation: string) =>
  (body: unknown): Effect.Effect<A, UpstreamError> =>
    Schema.decodeUnknown(schema)(body).pipe(Effect.mapError(() => new UpstreamError({ operation, status: null })));

export function makeUpstreamSnapshots(config: UpstreamConfig): UpstreamSnapshotsService {
  const http = makeUpstreamHttp(config);
  const created = new WeakSet<CreatedSnapshot>();

  /** One import's provider slug: derived from (tenant, classic VM, migration), so a retry finds the first send's snapshot. */
  const classicSlug = (request: ClassicImportRequest) =>
    Effect.promise(() => classicImportDigest(request)).pipe(Effect.map((digest) => `cmux-${config.environment}-classic-${digest.slice(0, 40)}`));
  const sourceMismatch = (operation: string) => new UpstreamError({ operation, status: 409 });
  const findClassicImport: UpstreamSnapshotsService["findClassicImport"] = (request) =>
    Effect.gen(function* () {
      const slug = yield* classicSlug(request);
      const body = yield* http
        .json("findClassicImport", "GET", `/v5/snapshots/${encodeURIComponent(slug)}`)
        .pipe(Effect.catchAll((error) => (error.status === 404 ? Effect.succeed(null) : Effect.fail(error))));
      if (body === null) return null;
      const snapshot = yield* decodeAs(ClassicImportSnapshot, "findClassicImport")(body);
      if (snapshot.sourceVmId !== request.upstreamVmId) return yield* Effect.fail(sourceMismatch("findClassicImport"));
      // Adopted, not created here: never a value discardCreatedSnapshot accepts.
      return Object.freeze({ upstreamId: snapshot.id, snapshot });
    });

  return {
    findClassicImport,
    captureClassicImport: (request, proofs) =>
      Effect.gen(function* () {
        const slug = yield* classicSlug(request);
        const sent = yield* http
          .json("captureClassicImport", "POST", `/v5/vms/${encodeURIComponent(request.upstreamVmId)}/snapshot`, { slug, displayName: `cmux classic import ${slug}` }, { timeoutMs: 120_000 })
          .pipe(Effect.either);
        if (sent._tag === "Left") {
          // 409 may be this slug already taken by an earlier send of the same import: adopt that one.
          if (sent.left.status === 409) {
            const found = yield* findClassicImport(request, proofs);
            if (found !== null) return found;
          }
          return yield* Effect.fail(sent.left);
        }
        const decoded = yield* decodeAs(ClassicImportCreated, "captureClassicImport")(sent.right);
        if (decoded.snapshotId !== decoded.snapshot.id || decoded.snapshot.sourceVmId !== request.upstreamVmId) {
          return yield* Effect.fail(new UpstreamError({ operation: "captureClassicImport", status: null }));
        }
        const result: CreatedSnapshot = Object.freeze({ upstreamId: decoded.snapshotId, snapshot: decoded.snapshot });
        created.add(result);
        return result;
      }),
    deleteClassicImport: (_snapshot, { owns }) =>
      http.json("deleteClassicImport", "DELETE", `/v5/snapshots/${proofSegment(owns)}`).pipe(Effect.asVoid),
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
