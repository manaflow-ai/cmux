/** A single durable capture send; retries adopt only an exactly correlated private snapshot. */
import { Effect, Redacted, Schema } from "effect";
import { UpstreamId } from "../lib/ids.ts";
import { TenantLimits } from "../limits/service.ts";
import type { SnapshotCaptureIntent } from "../limits/snapshot-capture.ts";
import { snapshotCaptureEvidenceOf } from "../proofs/snapshot-capture.ts";
import { upstreamIdOf } from "../proofs/tenant-owns-resource.ts";
import { UpstreamError } from "./client.ts";
import type { UpstreamHttp } from "./live-http.ts";
import type { UpstreamConfig } from "./live.ts";
import { UpstreamSnapshot, type CreatedSnapshot, type UpstreamSnapshotsService } from "./snapshots.ts";

const ProviderSnapshot = Schema.Struct({
  ...UpstreamSnapshot.fields, id: UpstreamId, slug: Schema.String, displayName: Schema.String,
  sourceVmId: UpstreamId, public: Schema.optional(Schema.Boolean),
});
const Created = Schema.Struct({ snapshotId: UpstreamId, snapshot: ProviderSnapshot });
const digest = (value: unknown) => Effect.promise(async () => {
  const bytes = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify(value)));
  return Array.from(new Uint8Array(bytes), (b) => b.toString(16).padStart(2, "0")).join("");
});
const failure = () => new UpstreamError({ operation: "snapshotCapture", status: null });
const decode = <A, I>(schema: Schema.Schema<A, I>, value: unknown) => Schema.decodeUnknown(schema)(value).pipe(Effect.mapError(failure));
const capped = (requested: number | null, actual: number | null | undefined) => requested === null || (actual !== null && actual !== undefined && Number.isFinite(actual) && actual > 0 && actual <= requested);

export const makeSnapshotCaptureClient = (config: UpstreamConfig, http: UpstreamHttp, mint: (value: CreatedSnapshot) => CreatedSnapshot): Pick<UpstreamSnapshotsService, "prepareCapture" | "capture" | "recoverCapture"> => {
  const context = () => digest(["snapshot-context:v1", config.baseUrl, config.environment, Redacted.value(config.apiKey)]);
  const slug = (intent: SnapshotCaptureIntent) => `cmux-${config.environment}-${intent.id.replaceAll("_", "-")}`;
  const probe = (intent: SnapshotCaptureIntent, source: string) => Effect.gen(function* () {
    const provider = yield* context();
    return { context: provider, source: yield* digest(source), stamp: `cmux-snapshot:${yield* digest(["capture:v1", provider, source, intent])}` };
  });
  const verify = (record: ReturnType<typeof snapshotCaptureEvidenceOf>, value: unknown) => Effect.gen(function* () {
    if (record.probe === undefined || record.probe.context !== (yield* context())) return yield* Effect.fail(failure());
    const snapshot = yield* decode(ProviderSnapshot, value);
    if (snapshot.slug !== slug(record.intent) || snapshot.displayName !== record.probe.stamp
      || (yield* digest(snapshot.sourceVmId)) !== record.probe.source) return yield* Effect.fail(failure());
    if (record.state !== "cancelling" && (snapshot.public === true || !capped(record.intent.ttlSeconds, snapshot.ttlSeconds) || !capped(record.intent.autoDeleteSeconds, snapshot.autoDeleteSeconds))) return yield* Effect.fail(failure());
    return mint(Object.freeze({ upstreamId: snapshot.id, snapshot }));
  });
  const recoverCapture: UpstreamSnapshotsService["recoverCapture"] = (_snapshot, { capture }) => Effect.gen(function* () {
    const record = snapshotCaptureEvidenceOf(capture);
    if (record.probe === undefined || record.probe.context !== (yield* context())) return yield* Effect.fail(failure());
    const value = yield* http.json("recoverSnapshotCapture", "GET", `/v5/snapshots/${encodeURIComponent(slug(record.intent))}`)
      .pipe(Effect.catchAll((error) => error.status === 404 ? Effect.succeed(null) : Effect.fail(error)));
    return value === null ? null : yield* verify(record, value);
  });
  return {
    prepareCapture: (_vm, { owns }, intent) => probe(intent, upstreamIdOf(owns)),
    recoverCapture,
    capture: (vm, snapshot, proofs, tenantId) => Effect.gen(function* () {
      const record = snapshotCaptureEvidenceOf(proofs.capture);
      if (record.state !== "pending" || record.intent.id !== snapshot.value || record.intent.sourceVmId !== vm.value
        || record.reservationId !== proofs.mayCreate.reservationId || JSON.stringify(record.probe) !== JSON.stringify(yield* probe(record.intent, upstreamIdOf(proofs.owns)))) return yield* Effect.fail(failure());
      const recovered = yield* recoverCapture(snapshot, proofs);
      if (recovered !== null) return recovered;
      const limits = yield* TenantLimits, token = crypto.randomUUID();
      const sent = yield* limits.snapshotCapture(tenantId, { op: "send", id: snapshot.value, token }).pipe(Effect.mapError(failure));
      if (sent.state !== "record" || !sent.granted) return yield* Effect.fail(failure());
      const body = yield* http.json("captureSnapshot", "POST", `/v5/vms/${encodeURIComponent(upstreamIdOf(proofs.owns))}/snapshot`, {
        slug: slug(record.intent), displayName: record.probe?.stamp,
        ...(record.intent.ttlSeconds === null ? {} : { ttlSeconds: record.intent.ttlSeconds }),
        ...(record.intent.autoDeleteSeconds === null ? {} : { autoDeleteSeconds: record.intent.autoDeleteSeconds }),
      }, { timeoutMs: 120_000 }).pipe(Effect.tapError((error) => error.status === 404 || error.status === 409
        ? limits.snapshotCapture(tenantId, { op: "reject", id: snapshot.value, token }).pipe(Effect.mapError(failure), Effect.asVoid)
        : Effect.void));
      const decoded = yield* decode(Created, body);
      if (decoded.snapshotId !== decoded.snapshot.id) return yield* Effect.fail(failure());
      return yield* verify(record, decoded.snapshot);
    }),
  };
};
