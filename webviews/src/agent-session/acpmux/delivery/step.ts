// A composer prompt's delivery machine (RFD 0026, machine 2), replayed from the table Rust exports
// (cmux-tui/crates/acpmux-client/src/delivery.rs, schemas/composer-delivery/table.json). This file
// holds no transition logic of its own: each step looks up the (state, event) row and builds the
// next state's data by the table's `generations` and `data` rules. Rust's exhaustive test proves
// the table sends one `session/prompt` per promptId; step.test.ts replays the table and Rust's
// vectors here.
import table from "../../../../../schemas/composer-delivery/table.json";

export type DeliveryHop = "connection" | "acpmux" | "agent";
export type FailCause = "refused" | "unanswered";

/// Rust `Hold`: why the pane holds the prompt.
export type DeliveryHold =
  | { reason: "trust" }
  | { reason: "machine_waking" }
  | { reason: "host_starting"; attempt: number; resent: boolean; behindTurn: boolean };

/// Rust `Delivery`, as it serializes.
export type DeliveryState =
  | { state: "draft" }
  | { state: "sending"; attempt: number; slow: boolean }
  | { state: "queued_behind_turn"; attempt: number; slow: boolean }
  | { state: "held"; hold: DeliveryHold }
  | { state: "delivered"; attempt: number }
  | { state: "read"; attempt: number }
  | { state: "failed"; attempt: number; hop: DeliveryHop; code: string; cause: FailCause };

/// Rust `Machine`: the delivery and the last generation it wrote `session/prompt` under.
export type DeliveryMachine = { delivery: DeliveryState; issued: number };

/// Rust `Event`, as it serializes.
export type DeliveryEvent =
  | { event: "submit" }
  | { event: "submit_behind_turn" }
  | { event: "hold_trust" }
  | { event: "hold_machine_waking" }
  | { event: "release" }
  | { event: "accepted" }
  | { event: "read" }
  | { event: "refused"; generation: number; hop: DeliveryHop; code: string }
  | { event: "unanswered"; generation: number; hop: DeliveryHop; code: string }
  | { event: "host_away"; generation: number }
  | { event: "slow_timer"; generation: number }
  | { event: "fail_timer"; generation: number }
  | { event: "hand_back" };

export type DeliveryEffect =
  | { effect: "send_prompt"; generation: number }
  | { effect: "arm_timers"; generation: number }
  | { effect: "clear_timers" };

export type DeliveryRefusal = (typeof table.refusals)[number];

export type DeliveryStep =
  | { ok: true; machine: DeliveryMachine; effects: DeliveryEffect[] }
  | { ok: false; refusal: DeliveryRefusal };

type StateRow = (typeof table.states)[number];
type Row = {
  from: string;
  event: string;
  to?: string;
  effects?: string[];
  refusal?: string;
  set?: { hop?: string; code?: string };
};

const STATES = new Map<string, StateRow>(table.states.map((row) => [row.key, row]));
const ROWS = new Map<string, Row>((table.transitions as Row[]).map((row) => [`${row.from}|${row.event}`, row]));

/// The codes that mean no answer came (a deadline, a dropped connection), not a refusal.
export const UNANSWERED_CODES: readonly string[] = table.unansweredCodes;

/// The table key of `delivery`: its state and the data that changes its row.
export function deliveryKey(delivery: DeliveryState): string {
  switch (delivery.state) {
    case "draft":
    case "delivered":
    case "read":
      return delivery.state;
    case "sending":
    case "queued_behind_turn":
      return delivery.slow ? `${delivery.state}_slow` : delivery.state;
    case "held": {
      const { hold } = delivery;
      if (hold.reason !== "host_starting") return `held_${hold.reason}`;
      return `held_host_starting${hold.resent ? "_resent" : ""}${hold.behindTurn ? "_behind_turn" : ""}`;
    }
    case "failed":
      return delivery.cause === "unanswered" ? "failed_unanswered" : "failed";
  }
}

/// What the table says of `delivery`: its pane word, hold and flags.
export function deliveryFacts(delivery: DeliveryState): StateRow {
  return STATES.get(deliveryKey(delivery))!;
}

function attemptOf(delivery: DeliveryState): number | undefined {
  switch (delivery.state) {
    case "draft":
      return undefined;
    case "held":
      return delivery.hold.reason === "host_starting" ? delivery.hold.attempt : undefined;
    case "sending":
    case "queued_behind_turn":
    case "delivered":
    case "read":
    case "failed":
      return delivery.attempt;
  }
}

/// The state a table key names, with its data: `attempt`, and a failure's hop and code.
function stateOf(key: string, attempt: number, failure: { hop: DeliveryHop; code: string }): DeliveryState {
  const facts = STATES.get(key)!;
  switch (facts.state) {
    case "draft":
      return { state: "draft" };
    case "sending":
    case "queued_behind_turn":
      return { state: facts.state, attempt, slow: facts.slow };
    case "held":
      if (facts.hold === "trust") return { state: "held", hold: { reason: "trust" } };
      if (facts.hold === "machine_waking") return { state: "held", hold: { reason: "machine_waking" } };
      return {
        state: "held",
        hold: { reason: "host_starting", attempt, resent: key.includes("_resent"), behindTurn: facts.behindTurn },
      };
    case "delivered":
    case "read":
      return { state: facts.state, attempt };
    case "failed":
      return { state: "failed", attempt, ...failure, cause: key === "failed_unanswered" ? "unanswered" : "refused" };
  }
  throw new Error(`composer-delivery table: unknown state ${facts.state}`);
}

/// The machine after `event`, and the effects to run; or the table's refusal.
export function deliveryStep(machine: DeliveryMachine, event: DeliveryEvent): DeliveryStep {
  const key = deliveryKey(machine.delivery);
  const row = ROWS.get(`${key}|${event.event}`);
  if (!row) throw new Error(`composer-delivery table: no row for ${key} ${event.event}`);
  const attempt = attemptOf(machine.delivery);
  // The table's stale rule: an answer or timer under another generation than the attempt.
  if ("generation" in event && row.to !== undefined && event.generation !== attempt)
    return { ok: false, refusal: "stale_generation" };
  if (row.refusal !== undefined) return { ok: false, refusal: row.refusal as DeliveryRefusal };
  // The table's generations rule: a row that writes takes the next generation.
  const writes = row.effects!.includes("send_prompt");
  const issued = writes ? machine.issued + 1 : machine.issued;
  const was = machine.delivery.state === "failed" ? machine.delivery : undefined;
  const carried = "hop" in event ? { hop: event.hop, code: event.code } : undefined;
  const failure = {
    hop: (row.set?.hop ?? carried?.hop ?? was?.hop ?? "acpmux") as DeliveryHop,
    code: row.set?.code ?? carried?.code ?? was?.code ?? "",
  };
  const delivery = stateOf(row.to!, writes ? issued : (attempt ?? 0), failure);
  const effects = row.effects!.map((kind): DeliveryEffect => {
    if (kind === "clear_timers") return { effect: "clear_timers" };
    return { effect: kind as "send_prompt" | "arm_timers", generation: issued };
  });
  return { ok: true, machine: { delivery, issued }, effects };
}

/// A prompt in the composer: nothing written.
export const DRAFT: DeliveryMachine = { delivery: { state: "draft" }, issued: 0 };

/// The flags the pane's `PromptDelivery` shows, as the machine's projection: one writer for them.
export function deliveryFlags(delivery: DeliveryState): {
  slow?: true;
  queued?: true;
  waitingForHost?: true;
} {
  const facts = deliveryFacts(delivery);
  return {
    ...(facts.slow ? { slow: true as const } : {}),
    ...(facts.behindTurn ? { queued: true as const } : {}),
    ...(facts.heldForHost ? { waitingForHost: true as const } : {}),
  };
}
