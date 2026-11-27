/** Permanent snapshot commands. No provider identifiers or caller-supplied keys are stored. */
import { Schema } from "effect";
import { SnapshotId, VmId } from "../lib/ids.ts";
import type { LedgerStorage } from "./ledger.ts";

export const SnapshotCaptureIntent = Schema.Struct({
  id: SnapshotId, sourceVmId: VmId, displayName: Schema.NullOr(Schema.String),
  labels: Schema.Record({ key: Schema.String, value: Schema.String }),
  createdBy: Schema.String, createdAt: Schema.String,
  ttlSeconds: Schema.NullOr(Schema.Number), autoDeleteSeconds: Schema.NullOr(Schema.Number),
});
export type SnapshotCaptureIntent = typeof SnapshotCaptureIntent.Type;
export const SnapshotCaptureProbe = Schema.Struct({ context: Schema.String, source: Schema.String, stamp: Schema.String });
export type SnapshotCaptureProbe = typeof SnapshotCaptureProbe.Type;
export const SnapshotCapture = Schema.Struct({
  phase: Schema.Literal("snapshotCapture"), key: Schema.String, fingerprint: Schema.String,
  intent: SnapshotCaptureIntent,
  state: Schema.Literal("claimed", "pending", "committed", "cancelling", "cancelled"),
  nonce: Schema.String, leaseUntilMs: Schema.Number,
  probe: Schema.optional(SnapshotCaptureProbe), reservationId: Schema.optional(Schema.String),
  dispatch: Schema.optional(Schema.Struct({ state: Schema.Literal("ready", "sent", "rejected"), token: Schema.String })),
});
export type SnapshotCapture = typeof SnapshotCapture.Type;
export const SnapshotCaptureResult = Schema.Union(
  Schema.Struct({ state: Schema.Literal("record"), record: SnapshotCapture, granted: Schema.Boolean }),
  Schema.Struct({ state: Schema.Literal("absent", "mismatch", "legacy") }),
  Schema.Struct({ state: Schema.Literal("legacyDone"), id: Schema.String }),
  Schema.Struct({ state: Schema.Literal("page"), items: Schema.Array(SnapshotCapture), nextCursor: Schema.NullOr(Schema.String) }),
);
export type SnapshotCaptureResult = typeof SnapshotCaptureResult.Type;
export type SnapshotCaptureCommand =
  | { readonly op: "list"; readonly cursor?: string; readonly limit: number }
  | { readonly op: "inspect"; readonly key: string }
  | { readonly op: "get"; readonly id: SnapshotId }
  | { readonly op: "begin"; readonly key: string; readonly fingerprint: string; readonly intent: SnapshotCaptureIntent; readonly nonce: string }
  | { readonly op: "prepare"; readonly id: SnapshotId; readonly nonce: string; readonly probe: SnapshotCaptureProbe; readonly reservationId: string }
  | { readonly op: "send" | "reject"; readonly id: SnapshotId; readonly token: string }
  | { readonly op: "commit" | "cancel" | "cancelled" | "yield" | "reservation"; readonly id: SnapshotId };

const isCapture = Schema.is(SnapshotCapture);
const Reservation = Schema.Struct({ kind: Schema.String, expiresMs: Schema.Number, retained: Schema.optional(Schema.Boolean), owner: Schema.optional(Schema.String) });
const isReservation = Schema.is(Reservation);
const Legacy = Schema.Struct({ fingerprint: Schema.String, progress: Schema.Struct({ phase: Schema.String, snapshotId: Schema.optional(Schema.String) }) });
const isLegacy = Schema.is(Legacy);
const ProtectedLegacy = Schema.Struct({ fingerprint: Schema.String, progress: Schema.Struct({ phase: Schema.Literal("snapshotLegacy"), snapshotId: Schema.optional(Schema.String) }) });
const isProtectedLegacy = Schema.is(ProtectedLegacy);
const recordResult = (record: SnapshotCapture, granted = false): SnapshotCaptureResult => ({ state: "record", record, granted });

/** One transaction also binds the quota slot before any potentially allocating provider send. */
export const snapshotCapture = (storage: LedgerStorage, command: SnapshotCaptureCommand, nowMs: number): Promise<SnapshotCaptureResult> =>
  storage.transaction(async (tx) => {
    if (command.op === "list") {
      if (!Number.isSafeInteger(command.limit) || command.limit < 1 || command.limit > 100 || (command.cursor !== undefined && !/^[a-f0-9]{16}-snap_[0-9a-hjkmnp-tv-z]{26}$/.test(command.cursor))) throw new Error("invalid capture page");
      const prefix = "snapshot-history:", items: SnapshotCapture[] = [];
      const rows = [...await tx.list({ prefix, ...(command.cursor === undefined ? {} : { startAfter: prefix + command.cursor }), limit: command.limit + 1 })];
      for (const [, id] of rows.slice(0, command.limit)) {
        if (typeof id !== "string") continue;
        const key = await tx.get(`snapshot-key:${id}`);
        const record = typeof key === "string" ? await tx.get(`idem:${key}`) : undefined;
        if (isCapture(record) && record.intent.id === id) items.push(record);
      }
      return { state: "page", items, nextCursor: rows.length > command.limit ? rows[command.limit - 1]?.[0].slice(prefix.length) ?? null : null };
    }
    const key = "key" in command ? command.key : await tx.get(`snapshot-key:${command.id}`);
    if (typeof key !== "string") return { state: "absent" };
    const raw = await tx.get(`idem:${key}`);
    if (command.op === "inspect" || command.op === "get") {
      if (isCapture(raw)) return recordResult(raw);
      if (raw === undefined) return { state: "absent" };
      if (isProtectedLegacy(raw)) return raw.progress.snapshotId === undefined ? { state: "legacy" } : { state: "legacyDone", id: raw.progress.snapshotId };
      if (isLegacy(raw) && raw.progress.phase === "snapshotDone" && raw.progress.snapshotId !== undefined) return { state: "legacyDone", id: raw.progress.snapshotId };
      return { state: "legacy" };
    }
    if (command.op === "begin") {
      if (isProtectedLegacy(raw)) {
        if (raw.fingerprint !== command.fingerprint) return { state: "mismatch" };
        return raw.progress.snapshotId === undefined ? { state: "legacy" } : { state: "legacyDone", id: raw.progress.snapshotId };
      }
      if (raw !== undefined && !isCapture(raw)) {
        if (!isLegacy(raw) || raw.fingerprint !== command.fingerprint) return { state: "mismatch" };
        const done = raw.progress.phase === "snapshotDone" ? raw.progress.snapshotId : undefined;
        await tx.put(`idem:${key}`, { fingerprint: raw.fingerprint, progress: { phase: "snapshotLegacy", ...(done === undefined ? {} : { snapshotId: done }) } });
        if (done !== undefined) return { state: "legacyDone", id: done };
        // Legacy claimed/pending may already have sent. Never recapture, even after their former TTL.
        return { state: "legacy" };
      }
      if (isCapture(raw)) {
        if (raw.fingerprint !== command.fingerprint) return { state: "mismatch" };
        if (raw.state !== "claimed" || raw.leaseUntilMs > nowMs) return recordResult(raw);
        const record = { ...raw, nonce: command.nonce, leaseUntilMs: nowMs + 600_000 };
        await tx.put(`idem:${key}`, record);
        return recordResult(record, true);
      }
      const record: SnapshotCapture = { phase: "snapshotCapture", key, fingerprint: command.fingerprint, intent: command.intent,
        state: "claimed", nonce: command.nonce, leaseUntilMs: nowMs + 600_000 };
      await tx.put(`idem:${key}`, record);
      await tx.put(`snapshot-key:${command.intent.id}`, key);
      await tx.put(`snapshot-history:${(Number.MAX_SAFE_INTEGER - nowMs).toString(16).padStart(16, "0")}-${command.intent.id}`, command.intent.id);
      return recordResult(record, true);
    }
    if (!isCapture(raw) || raw.intent.id !== command.id) return { state: "absent" };
    let record: SnapshotCapture = raw;
    let granted = false;
    switch (command.op) {
      case "yield":
        if (raw.state !== "claimed") return recordResult(raw);
        record = { ...raw, leaseUntilMs: 0 }; granted = true;
        break;
      case "reservation": {
        if (raw.state !== "pending" || raw.reservationId === undefined) return recordResult(raw);
        const held = await tx.get(`reserve:${raw.reservationId}`);
        return recordResult(raw, isReservation(held) && held.kind === "snapshot" && held.retained === true && held.owner === raw.intent.id);
      }
      case "prepare": {
        if (raw.state !== "claimed" || raw.nonce !== command.nonce || raw.leaseUntilMs <= nowMs) return recordResult(raw);
        const held = await tx.get(`reserve:${command.reservationId}`);
        if (!isReservation(held) || held.kind !== "snapshot" || held.retained === true || held.expiresMs <= nowMs) return recordResult(raw);
        await tx.put(`reserve:${command.reservationId}`, { ...held, retained: true, owner: raw.intent.id });
        record = { ...raw, state: "pending", probe: command.probe, reservationId: command.reservationId, dispatch: { state: "ready", token: "" } };
        granted = true;
        break;
      }
      case "send":
        if (raw.state !== "pending" || raw.dispatch === undefined || raw.dispatch.state === "sent") return recordResult(raw);
        record = { ...raw, dispatch: { state: "sent", token: command.token } }; granted = true;
        break;
      case "reject":
        if (raw.dispatch?.state !== "sent" || raw.dispatch.token !== command.token || (raw.state !== "pending" && raw.state !== "cancelling")) return recordResult(raw);
        record = { ...raw, state: raw.state === "cancelling" ? "cancelled" : "pending", dispatch: { state: "rejected", token: command.token } };
        granted = true;
        break;
      case "commit":
        if (raw.state !== "pending") return recordResult(raw, raw.state === "committed");
        record = { ...raw, state: "committed" }; granted = true;
        break;
      case "cancel":
        if (raw.state === "committed") return recordResult(raw);
        if (raw.state === "cancelled" || raw.state === "cancelling") return recordResult(raw, true);
        record = { ...raw, state: raw.dispatch?.state === "sent" ? "cancelling" : "cancelled" }; granted = true;
        break;
      case "cancelled":
        if (raw.state !== "cancelling") return recordResult(raw, raw.state === "cancelled");
        record = { ...raw, state: "cancelled" }; granted = true;
        break;
    }
    if (record.state === "committed" || record.state === "cancelled") {
      if (record.reservationId !== undefined) await tx.delete(`reserve:${record.reservationId}`);
    }
    await tx.put(`idem:${key}`, record);
    return recordResult(record, granted);
  });
