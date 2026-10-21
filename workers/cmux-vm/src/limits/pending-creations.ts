/** Pending discovery is bounded by active VM slots, not permanent history size. */
import { Schema } from "effect";
import { PENDING_CREATION_CURSOR, type GeneratedCreation, type GeneratedCreationPage } from "../domain/generated-creation.ts";
import type { IdempotencyRecord, LedgerStorage } from "./ledger.ts";

const VmReservationLink = Schema.Struct({ key: Schema.String, vmId: Schema.String });
const Reservation = Schema.Struct({ kind: Schema.String, expiresMs: Schema.Number,
  retained: Schema.optional(Schema.Boolean), vmCreation: Schema.optional(Schema.Unknown) });
type Reservation = typeof Reservation.Type;
const Migration = Schema.Struct({ targets: Schema.Array(Schema.String), after: Schema.optional(Schema.String),
  exhausted: Schema.Boolean, token: Schema.String });
const isReservation = Schema.is(Reservation), isMigration = Schema.is(Migration), isLink = Schema.is(VmReservationLink);
const MIGRATION_KEY = "maintenance:pending-creations";

export const pendingCreations = (storage: LedgerStorage, scope: string, cursor: string | undefined, limit: number,
  readRecord: (value: unknown) => IdempotencyRecord | undefined): Promise<GeneratedCreationPage> => storage.transaction(async (tx) => {
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > 100 || (cursor !== undefined && !PENDING_CREATION_CURSOR.test(cursor))) throw new Error("invalid pending creation page");
  const anchor = cursor?.startsWith("p1_") ? cursor.slice(3) : cursor?.startsWith("i1_") && cursor.length > 35 ? cursor.slice(36) : undefined;
  const slots = new Map<string, Reservation>();
  let completeness: "ready" | "unavailable" = "ready";
  for (const [key, value] of await tx.list({ prefix: "reserve:" })) {
    if (isReservation(value) && value.kind === "vm" && value.retained === true) slots.set(key, value);
    else if (typeof value === "object" && value !== null && "kind" in value && value.kind === "vm"
      && "retained" in value && value.retained === true) completeness = "unavailable";
  }
  const missing = () => [...slots].filter(([, value]) => value.vmCreation === undefined).map(([key]) => key);
  const unbound = missing();
  if (unbound.length > 0) {
    const raw = await tx.get(MIGRATION_KEY);
    const previous = isMigration(raw) ? raw : undefined;
    const restart = previous === undefined || unbound.some(key => !previous.targets.includes(key)) || (previous.exhausted && cursor === undefined);
    const after = restart ? undefined : previous?.after;
    const rows = restart || !previous?.exhausted
      ? await tx.list({ prefix: "idem:", ...(after === undefined ? {} : { startAfter: after }), limit: 64 }) : new Map<string, unknown>();
    for (const [key, value] of rows) {
      const record = readRecord(value), p = record?.progress;
      if (p?.phase !== "creating" && p?.phase !== "capturing") continue;
      const slotKey = `reserve:${p.reservationId}`, held = slots.get(slotKey);
      if (held === undefined || held.vmCreation !== undefined) continue;
      const bound = { ...held, vmCreation: { key: key.slice("idem:".length), vmId: p.vmId } };
      await tx.put(slotKey, bound);
      slots.set(slotKey, bound);
    }
    const remaining = missing();
    if (remaining.length > 0) {
      const exhausted = rows.size < 64, token = crypto.randomUUID().replaceAll("-", "");
      const last = [...rows.keys()].at(-1) ?? after;
      await tx.put(MIGRATION_KEY, { targets: remaining, ...(last === undefined ? {} : { after: last }), exhausted, token });
      if (!exhausted) return { items: [], nextCursor: `i1_${token}${anchor === undefined ? "" : `_${anchor}`}`, pendingIndex: "building" };
      completeness = "unavailable";
    } else await tx.delete(MIGRATION_KEY);
  } else await tx.delete(MIGRATION_KEY);

  const candidates: Array<{ generated: GeneratedCreation; position: string }> = [];
  for (const [slotKey, held] of slots) {
    const link = held.vmCreation;
    if (!isLink(link)) { if (link !== undefined) completeness = "unavailable"; continue; }
    const record = readRecord(await tx.get(`idem:${link.key}`)), p = record?.progress;
    if ((p?.phase !== "creating" && p?.phase !== "capturing") || p.vmId !== link.vmId || `reserve:${p.reservationId}` !== slotKey) {
      completeness = "unavailable";
      continue;
    }
    const generated = record?.generated;
    if (generated === undefined || generated.scope !== scope) continue;
    const time = Date.parse(generated.createdAt);
    if (!Number.isSafeInteger(time) || time < 0) { completeness = "unavailable"; continue; }
    const position = `${(Number.MAX_SAFE_INTEGER - time).toString(16).padStart(16, "0")}-${generated.cursor}`;
    if (anchor !== undefined && position <= anchor) continue;
    candidates.push({ generated, position });
  }
  candidates.sort((a, b) => a.position < b.position ? -1 : a.position > b.position ? 1 : 0);
  const page = candidates.slice(0, limit);
  const last = page.at(-1);
  return { items: page.map(x => x.generated), pendingIndex: completeness,
    nextCursor: candidates.length > limit && last !== undefined ? `p1_${last.position}` : null };
});
