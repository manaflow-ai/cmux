// The pane's `PromptDelivery` record (model.ts) on the composer delivery machine (step.ts): what
// each change the send flow makes means as the machine's event, and the record's flags as the
// machine's projection, so the table alone decides which changes land (RFD 0026).
import type { PromptDelivery } from "../model";
import {
  DRAFT,
  type DeliveryEvent,
  type DeliveryMachine,
  type DeliveryState,
  UNANSWERED_CODES,
  deliveryFacts,
  deliveryFlags,
  deliveryStep,
} from "./step";

function attemptOf(delivery: DeliveryState): number {
  if (delivery.state === "draft") return 0;
  if (delivery.state === "held") return delivery.hold.reason === "host_starting" ? delivery.hold.attempt : 0;
  return delivery.attempt;
}

/// A send of the prompt: its first, or a Retry of a failed one under the same promptId. A steer
/// goes behind the running turn.
export function sentDelivery(before: DeliveryMachine | undefined, steer: boolean): DeliveryMachine {
  const event: DeliveryEvent = { event: steer ? "submit_behind_turn" : "submit" };
  const retried = before?.delivery.state === "failed" ? deliveryStep(before, event) : undefined;
  if (retried?.ok) return retried.machine;
  const sent = deliveryStep(DRAFT, event);
  if (!sent.ok) throw new Error(`composer-delivery table: a draft refuses ${event.event}`);
  return sent.machine;
}

/// A record drawn without this pane's send (a relaunch's Not sent row, a prompt the host sends
/// again): the machine at the state it shows, one write out or behind it.
export function drawnDelivery(delivery: PromptDelivery): DeliveryMachine {
  const sent = sentDelivery(undefined, delivery.queued === true);
  if (delivery.state === "sending") return sent;
  const code = delivery.code ?? "";
  const generation = attemptOf(sent.delivery);
  const event: DeliveryEvent =
    delivery.state === "failed"
      ? {
          event: UNANSWERED_CODES.includes(code) ? "unanswered" : "refused",
          generation,
          hop: delivery.hop ?? "connection",
          code,
        }
      : { event: delivery.state === "read" ? "read" : "accepted" };
  const drawn = deliveryStep(sent, event);
  return drawn.ok ? drawn.machine : sent;
}

/// The machine's event for a change to the record, under the attempt it waits on; none for a change
/// that moves nothing (times, words for Details).
export function deliveryEvent(machine: DeliveryMachine, patch: Partial<PromptDelivery>): DeliveryEvent | undefined {
  const generation = attemptOf(machine.delivery);
  switch (patch.state) {
    case "delivered":
      return { event: "accepted" };
    case "read":
      return { event: "read" };
    case "failed": {
      const code = patch.code ?? "";
      const taken = machine.delivery.state === "delivered" || machine.delivery.state === "read";
      // After acpmux took it only a refusal at its turn fails it; before, a code that means no
      // answer came is the deadline's, which a late acceptance still overrides.
      const unanswered = !taken && UNANSWERED_CODES.includes(code);
      return { event: unanswered ? "unanswered" : "refused", generation, hop: patch.hop ?? "acpmux", code };
    }
    case "sending":
    case undefined:
      break;
  }
  if (patch.waitingForHost === true) return { event: "host_away", generation };
  if (patch.slow === true) return { event: "slow_timer", generation };
  return undefined;
}

/// acpmux answered again after a hold: the held frame goes once more (sendWhenReady.ts).
export function releasedDelivery(machine: DeliveryMachine): DeliveryMachine | undefined {
  const released = deliveryStep(machine, { event: "release" });
  return released.ok ? released.machine : undefined;
}

/// The record as the machine has it: its state word and the flags that follow from the state.
/// `queued` (a steer's) is the send's, kept as it was.
export function projectDelivery(record: PromptDelivery, machine: DeliveryMachine): PromptDelivery {
  const word = deliveryFacts(machine.delivery).word;
  const next: PromptDelivery = { ...record, ...(word ? { state: word as PromptDelivery["state"] } : {}) };
  delete next.slow;
  delete next.waitingForHost;
  return { ...next, ...withoutQueued(deliveryFlags(machine.delivery)) };
}

function withoutQueued(flags: ReturnType<typeof deliveryFlags>): { slow?: true; waitingForHost?: true } {
  const { queued: _queued, ...rest } = flags;
  return rest;
}
