/** Compare the inspected id before fencing: a stale lookup must never delete a different capture. */
import { name } from "@gdp-ts/core";
import { Clock, Effect, Option } from "effect";
import { SnapshotKeyCancellation } from "../api/snapshots.ts";
import { SnapshotStore } from "../db/snapshots.ts";
import { actorRef } from "../domain/principal.ts";
import { Conflict, Forbidden, PaymentRequired, snapshotNotFound, unavailable } from "../errors.ts";
import { parseSnapshotId, type SnapshotId } from "../lib/ids.ts";
import { TenantLimits } from "../limits/service.ts";
import { authorizedSnapshotCapture, legacySnapshotCaptureStatus, snapshotFenceAllowed } from "../proofs/snapshot-capture.ts";
import { tenantOwnsSnapshot } from "../proofs/tenant-owns-resource.ts";
import { UpstreamSnapshots } from "../upstream/snapshots.ts";
import { Entitlements } from "../proofs/tenant-may-create.ts";
import { audited, withCaller } from "./common.ts";
import { reconcileCapturedSnapshot } from "./snapshot-capture.ts";

const changed = () => new Conflict({ message: "The capture changed; inspect this key before cancelling it" });
const digest = (key: string) => Effect.promise(async () => {
  const bytes = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify(["key", key])));
  return Array.from(new Uint8Array(bytes), (b) => b.toString(16).padStart(2, "0")).join("");
});

export const cancelSnapshotCaptureKey = (rawKey: string, expectedId: SnapshotId | null) => audited("snapshot.create.cancel", null,
  withCaller("snapshot:write", "write", (caller, scope) => Effect.gen(function* () {
    const principal = caller.value;
    if (principal.resourceAllowlist !== null) return yield* Effect.fail(new Forbidden({ message: "A key limited to specific resources must use id-addressed capture controls" }));
    const limits = yield* TenantLimits, key = yield* digest(rawKey);
    const found = yield* limits.snapshotCapture(principal.tenantId, { op: "inspect", key }).pipe(Effect.mapError(() => unavailable()));
    if (found.state === "absent" && !(yield* (yield* Entitlements).mayCreate(principal.tenantId, "snapshot").pipe(Effect.mapError(() => unavailable()))))
      return yield* Effect.fail(new PaymentRequired({ message: "This team's plan does not include new capture key reservations" }));
    if (found.state === "legacy") return yield* Effect.fail(new Conflict({ message: "This legacy capture has no safe cancellation identity" }));
    if (found.state === "record") {
      yield* name(found.record.intent.id, (snapshot) => authorizedSnapshotCapture(caller, snapshot).pipe(Effect.asVoid));
      if (found.record.intent.id !== expectedId) return yield* Effect.fail(changed());
    } else if (found.state === "legacyDone") {
      yield* legacySnapshotCaptureStatus(caller, found.id);
      if (found.id !== expectedId) return yield* Effect.fail(changed());
    } else if (expectedId !== null) return yield* Effect.fail(changed());
    if (found.state === "fenced" && !snapshotFenceAllowed(principal, found.fence)) return yield* Effect.fail(snapshotNotFound());
    const fenced = yield* limits.snapshotCapture(principal.tenantId, { op: "fence", key, expectedId,
      createdBy: actorRef(principal.actor), labels: principal.requiredLabels ?? {} }).pipe(Effect.mapError(() => unavailable()));
    if (fenced.state === "fenced" && fenced.granted) {
      if (!snapshotFenceAllowed(principal, fenced.fence)) return yield* Effect.fail(snapshotNotFound());
      return new SnapshotKeyCancellation({ state: "fenced", id: null });
    }
    if (fenced.state === "record" && fenced.granted) return yield* name(fenced.record.intent.id, (snapshot) =>
      reconcileCapturedSnapshot(caller, snapshot, scope).pipe(Effect.map((status) => new SnapshotKeyCancellation({
        id: snapshot.value, receipt: status.receipt, state: status.cancellation === "completed" ? "cancelled" : "cancelling",
      }))));
    if (fenced.state === "legacyDone") {
      const parsed = parseSnapshotId(fenced.id);
      if (Option.isNone(parsed)) return yield* Effect.fail(unavailable());
      const status = yield* legacySnapshotCaptureStatus(caller, fenced.id);
      if (status.state !== "deleted") yield* name(parsed.value, (snapshot) => Effect.gen(function* () {
        const owns = yield* tenantOwnsSnapshot(caller, snapshot).pipe(Effect.mapError(() => unavailable()));
        if (owns === null) return yield* Effect.fail(snapshotNotFound());
        yield* (yield* UpstreamSnapshots).deleteSnapshot(snapshot, { owns, scope }).pipe(Effect.catchAll((e) => e.status === 404 ? Effect.void : Effect.fail(unavailable())));
        yield* (yield* SnapshotStore).markDeleted(principal.tenantId, snapshot.value, new Date(yield* Clock.currentTimeMillis)).pipe(Effect.mapError(() => unavailable()));
      }));
      return new SnapshotKeyCancellation({ state: "cancelled", id: parsed.value, receipt: status.receipt });
    }
    return yield* Effect.fail(changed());
  })).pipe(Effect.uninterruptible), (value) => value.id);
