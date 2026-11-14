/**
 * An agent key's live-VM budget, admitted atomically in the tenant's ledger.
 *
 * A paid team has no machine count (Leo, 2026-11-10: "you can have arbitrarily many VMs"), so the tenant quota no
 * longer bounds an agent key; its own `maxVms` does, and a read-then-create check would let concurrent creates past
 * it. Each create holds a slot under `agentslot:<agent>:<slot>`, and admission counts, in one transaction, the union
 * of the VM ids the ownership table answered for the key and the VMs (or creates) its slots hold:
 *
 * - a fresh slot holds a create in flight (it counts once, as itself);
 * - a recorded create keeps its slot with the VM's id for `SETTLED_TTL_MS`, so a listing read before that VM's
 *   ownership row landed still counts it, and a fresh listing that has it counts it once;
 * - a create whose send began but whose recording failed may exist upstream unrecorded: its slot stays, naming the
 *   VM id its intent holds and bound to the creation key, until the VM is deleted, a retry records it, or
 *   `HELD_TTL_MS` passes;
 * - a create that failed before any send gives its slot back, and a deleted VM forgets the slot that names it.
 */
import { Schema } from "effect";
import type { LedgerStorage } from "./storage.ts";

/** A create in flight: longer than the idempotency lease (10 minutes), so a slow create never loses its slot. */
export const ADMIT_TTL_MS = 15 * 60_000;
/** How long a recorded VM's slot outlives it: far past any one request's ownership read. */
export const SETTLED_TTL_MS = 15 * 60_000;
/** A create that may exist upstream unrecorded: past the longest agent key (AGENT_LIMITS.ttlSeconds). */
export const HELD_TTL_MS = 25 * 3600_000;

const AgentSlot = Schema.Struct({
  expiresMs: Schema.Number,
  vmId: Schema.optional(Schema.String),
  creationKey: Schema.optional(Schema.String),
});
const isAgentSlot = Schema.is(AgentSlot);

const PREFIX = "agentslot:";
const prefixOf = (agent: string) => `${PREFIX}${agent}:`;

/** How a create ends for its slot. */
export type AgentSlotOutcome =
  | { readonly recorded: string }
  | { readonly held: string; readonly vmId: string }
  | "released";

/** Takes `slotId` when the key's VMs and creates in flight stay under `limit`; false at the budget. */
export const admitAgentSlot = (storage: LedgerStorage, agent: string, limit: number, ownedVmIds: ReadonlyArray<string>, nowMs: number, slotId: string): Promise<boolean> =>
  storage.transaction(async (tx) => {
    const held = new Set(ownedVmIds);
    for (const [key, value] of await tx.list({ prefix: prefixOf(agent) })) {
      if (!isAgentSlot(value) || value.expiresMs <= nowMs) await tx.delete(key);
      else held.add(value.vmId ?? key);
    }
    if (held.size >= limit) return false;
    await tx.put(`${prefixOf(agent)}${slotId}`, { expiresMs: nowMs + ADMIT_TTL_MS });
    return true;
  });

/** Ends a create's slot: keeps it naming the recorded VM, holds it for a create that may exist, or gives it back. */
export const settleAgentSlot = (storage: LedgerStorage, agent: string, slotId: string, outcome: AgentSlotOutcome, nowMs: number): Promise<void> =>
  storage.transaction(async (tx) => {
    const key = `${prefixOf(agent)}${slotId}`;
    if (outcome === "released") await tx.delete(key);
    else if ("recorded" in outcome) await tx.put(key, { expiresMs: nowMs + SETTLED_TTL_MS, vmId: outcome.recorded });
    else await tx.put(key, { expiresMs: nowMs + HELD_TTL_MS, creationKey: outcome.held, vmId: outcome.vmId });
  });

/** A retry of `creationKey` recorded `vmId`: its held slot now names that VM. */
export const bindAgentCreation = (storage: LedgerStorage, agent: string, creationKey: string, vmId: string, nowMs: number): Promise<void> =>
  storage.transaction(async (tx) => {
    for (const [key, value] of await tx.list({ prefix: prefixOf(agent) })) {
      if (isAgentSlot(value) && value.creationKey === creationKey) await tx.put(key, { expiresMs: nowMs + SETTLED_TTL_MS, vmId });
    }
  });

/** A deleted VM (or its cancelled creation) no longer counts against any agent key's budget. */
export const forgetAgentVm = (storage: LedgerStorage, vmId: string, creationKey: string | null): Promise<void> =>
  storage.transaction(async (tx) => {
    for (const [key, value] of await tx.list({ prefix: PREFIX })) {
      if (isAgentSlot(value) && (value.vmId === vmId || (creationKey !== null && value.creationKey === creationKey))) await tx.delete(key);
    }
  });
