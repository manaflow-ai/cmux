/** Tenant-owned mesh intents. This separate namespace/RPC makes an older ledger fail closed. */
import { Schema } from "effect";
import { MeshId } from "../lib/ids.ts";
import { Reservation, type LedgerStorage } from "./storage.ts";

const Digest = Schema.String.pipe(Schema.pattern(/^[0-9a-f]{64}$/u));
const Holder = Schema.String.pipe(Schema.minLength(1), Schema.maxLength(128));
const Identity = { key: Digest, meshId: MeshId };
const Lease = { ...Identity, holder: Holder };
const Dispatch = Schema.Struct({ state: Schema.Literal("ready", "sent", "rejected"), token: Schema.String });
const Labels = Schema.Record({ key: Schema.String, value: Schema.String });
export const MeshCreationRecord = Schema.Struct({
  version: Schema.Literal(1), fingerprint: Digest, meshId: MeshId,
  createdBy: Schema.String, createdAt: Schema.String, displayName: Schema.NullOr(Schema.String),
  phase: Schema.Literal("prepared", "creating", "done", "cancelling", "deleted"),
  reservationId: Schema.NullOr(Schema.String), context: Schema.NullOr(Digest), dispatch: Dispatch,
  holder: Holder, leaseUntilMs: Schema.Number,
  labels: Schema.optional(Labels),
});
export type MeshCreationRecord = typeof MeshCreationRecord.Type;
export const MeshCreationCommand = Schema.Union(
  Schema.Struct({ op: Schema.Literal("get"), key: Digest }),
  Schema.Struct({ op: Schema.Literal("begin"), key: Digest, fingerprint: Digest, meshId: MeshId, holder: Holder, createdBy: Schema.String, displayName: Schema.NullOr(Schema.String) }),
  // A distinct operation makes an older DO reject labelled intents before changing storage.
  Schema.Struct({ op: Schema.Literal("begin-labelled"), key: Digest, fingerprint: Digest, meshId: MeshId, holder: Holder, createdBy: Schema.String, displayName: Schema.NullOr(Schema.String), labels: Labels }),
  Schema.Struct({ op: Schema.Literal("retain"), ...Lease, reservationId: Schema.String }),
  Schema.Struct({ op: Schema.Literal("context"), ...Lease, context: Digest }),
  Schema.Struct({ op: Schema.Literal("send"), ...Lease, token: Holder }),
  Schema.Struct({ op: Schema.Literal("reject"), ...Identity, token: Holder }),
  Schema.Struct({ op: Schema.Literal("active"), ...Lease }),
  Schema.Struct({ op: Schema.Literal("reservation"), ...Identity }),
  Schema.Struct({ op: Schema.Literal("complete"), ...Identity }),
  Schema.Struct({ op: Schema.Literal("cancel", "cancelled"), ...Identity }),
  Schema.Struct({ op: Schema.Literal("abandon"), ...Lease }),
);
export type MeshCreationCommand = typeof MeshCreationCommand.Type;
export const MeshCreationResult = Schema.Union(
  Schema.Struct({ state: Schema.Literal("record"), record: MeshCreationRecord, acquired: Schema.Boolean }),
  Schema.Struct({ state: Schema.Literal("reservation"), reservationId: Schema.String }),
  Schema.Struct({ state: Schema.Literal("missing", "conflict", "ok", "denied") }),
);
export type MeshCreationResult = typeof MeshCreationResult.Type;
const LEASE_MS = 10 * 60_000;
const checked = Schema.is(MeshCreationRecord), held = Schema.is(Reservation);
const reply = (record: MeshCreationRecord, acquired = false): MeshCreationResult => ({ state: "record", record, acquired });

export const meshCreation = async (storage: LedgerStorage, input: MeshCreationCommand, now: number): Promise<MeshCreationResult> => {
  if (!Schema.is(MeshCreationCommand)(input) || !Number.isSafeInteger(now)) throw new Error("invalid mesh creation command");
  return storage.transaction(async (tx) => {
    const key = `mesh-create-v1:${input.key}`, raw = await tx.get(key);
    if (raw !== undefined && !checked(raw)) throw new Error("unrecognized mesh creation record");
    const prior = checked(raw) ? raw : null;
    if (input.op === "get") return prior ? reply(prior) : { state: "missing" };
    if (input.op === "begin" || input.op === "begin-labelled") {
      if (prior && prior.fingerprint !== input.fingerprint) return { state: "conflict" };
      const ordered = (labels: Readonly<Record<string, string>>) => Object.entries(labels).sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0);
      if (prior && JSON.stringify(ordered(prior.labels ?? {})) !== JSON.stringify(ordered(input.op === "begin-labelled" ? input.labels : {}))) return { state: "conflict" };
      if (prior && (["done", "cancelling", "deleted"].includes(prior.phase) || prior.leaseUntilMs > now)) return reply(prior);
      const record: MeshCreationRecord = prior ? { ...prior, holder: input.holder, leaseUntilMs: now + LEASE_MS } : {
        version: 1, fingerprint: input.fingerprint, meshId: input.meshId, createdBy: input.createdBy, displayName: input.displayName,
        createdAt: new Date(now).toISOString(), phase: "prepared", reservationId: null, context: null,
        dispatch: { state: "ready", token: "" }, holder: input.holder, leaseUntilMs: now + LEASE_MS,
        ...(input.op === "begin-labelled" ? { labels: input.labels } : {}),
      };
      await tx.put(key, record);
      return reply(record, true);
    }
    if (!prior || prior.meshId !== input.meshId) return { state: "denied" };
    const ownedLease = "holder" in input && input.holder === prior.holder && prior.leaseUntilMs > now;
    const pending = prior.phase === "prepared" || prior.phase === "creating";
    if (input.op === "abandon") {
      if (input.holder === prior.holder && pending) await tx.put(key, { ...prior, leaseUntilMs: 0 });
      return { state: "ok" };
    }
    if (input.op === "complete") {
      if (prior.phase !== "creating" && prior.phase !== "done") return { state: "denied" };
      if (prior.reservationId !== null) await tx.delete(`reserve:${prior.reservationId}`);
      const record: MeshCreationRecord = { ...prior, phase: "done", leaseUntilMs: 0 };
      await tx.put(key, record);
      return reply(record);
    }
    if (input.op === "cancel" || input.op === "cancelled") {
      if (input.op === "cancelled" && prior.phase !== "cancelling" && prior.phase !== "deleted") return { state: "denied" };
      if (input.op === "cancelled" && prior.reservationId !== null) await tx.delete(`reserve:${prior.reservationId}`);
      const record: MeshCreationRecord = { ...prior, phase: input.op === "cancelled" || prior.phase === "deleted" ? "deleted" : "cancelling", leaseUntilMs: 0 };
      await tx.put(key, record);
      return reply(record);
    }
    if (input.op === "reservation") {
      const reservation = prior.reservationId === null ? undefined : await tx.get(`reserve:${prior.reservationId}`);
      return pending && held(reservation) && reservation.kind === "mesh" && reservation.retained === true && prior.reservationId !== null
        ? { state: "reservation", reservationId: prior.reservationId } : { state: "denied" };
    }
    if (input.op === "reject") {
      if (!pending || prior.dispatch.state !== "sent" || prior.dispatch.token !== input.token) return { state: "denied" };
      const record: MeshCreationRecord = { ...prior, dispatch: { state: "rejected", token: input.token } };
      await tx.put(key, record);
      return reply(record);
    }
    if (!pending || !ownedLease) return { state: "denied" };
    if (input.op === "active") return { state: "ok" };
    if (input.op === "retain") {
      if (prior.reservationId !== null && prior.reservationId !== input.reservationId) return { state: "denied" };
      const reservation = await tx.get(`reserve:${input.reservationId}`);
      if (!held(reservation) || reservation.kind !== "mesh" || (reservation.retained !== true && reservation.expiresMs <= now)) return { state: "denied" };
      await tx.put(`reserve:${input.reservationId}`, { ...reservation, retained: true });
      const record: MeshCreationRecord = { ...prior, phase: "creating", reservationId: input.reservationId };
      await tx.put(key, record);
      return reply(record);
    }
    if (prior.phase !== "creating" || prior.reservationId === null) return { state: "denied" };
    if (input.op === "context") {
      if (prior.context !== null && prior.context !== input.context && prior.dispatch.state !== "rejected") return { state: "denied" };
      const record: MeshCreationRecord = { ...prior, context: input.context };
      await tx.put(key, record);
      return reply(record);
    }
    if (input.op === "send") {
      if (prior.context === null || prior.dispatch.state === "sent") return { state: "denied" };
      const record: MeshCreationRecord = { ...prior, dispatch: { state: "sent", token: input.token } };
      await tx.put(key, record);
      return reply(record);
    }
    return { state: "denied" };
  });
};
