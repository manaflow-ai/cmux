// The webviews replay the composer delivery table Rust exports (RFD 0026): every one of Rust's
// recorded walks comes out the same here, every row is decided, and every event sequence up to
// length 6 from a draft writes at most one `session/prompt` at a time, only on a send intent, and
// none after acpmux took the prompt.
import { describe, expect, test } from "bun:test";
import table from "../../../../../schemas/composer-delivery/table.json";
import vectors from "../../../../../schemas/composer-delivery/vectors.json";
import {
  DRAFT,
  type DeliveryEvent,
  type DeliveryMachine,
  type DeliveryState,
  deliveryFacts,
  deliveryFlags,
  deliveryKey,
  deliveryStep,
} from "./step";

type Walk = {
  before: DeliveryMachine;
  event: DeliveryEvent;
  after?: DeliveryMachine;
  effects?: unknown[];
  refusal?: string;
}[];

const INTENTS: DeliveryEvent[] = [
  { event: "submit" },
  { event: "submit_behind_turn" },
  { event: "hold_trust" },
  { event: "hold_machine_waking" },
  { event: "release" },
  { event: "accepted" },
  { event: "read" },
  { event: "hand_back" },
];

function answers(generation: number): DeliveryEvent[] {
  return [
    { event: "refused", generation, hop: "agent", code: "agent.error" },
    { event: "unanswered", generation, hop: "connection", code: "timeout" },
    { event: "host_away", generation },
    { event: "slow_timer", generation },
    { event: "fail_timer", generation },
  ];
}

describe("composer delivery replays Rust's table", () => {
  test("every walk Rust recorded comes out the same", () => {
    const walks = (vectors as { walks: Walk[] }).walks ?? (vectors as unknown as Walk[]);
    expect(walks.length).toBeGreaterThan(0);
    let steps = 0;
    for (const walk of walks) {
      for (const record of walk) {
        const result = deliveryStep(record.before, record.event);
        if (record.refusal !== undefined) {
          expect(result).toEqual({ ok: false, refusal: record.refusal as never });
        } else {
          expect(result).toEqual({ ok: true, machine: record.after!, effects: record.effects as never });
        }
        steps += 1;
      }
    }
    expect(steps).toBeGreaterThan(100);
  });

  test("every state key the table names round-trips, and the pane flags follow it", () => {
    for (const row of table.states) {
      const machine = reach(row.key);
      expect(machine, row.key).toBeDefined();
      const facts = deliveryFacts(machine!.delivery);
      expect(facts.key).toBe(row.key);
      const flags = deliveryFlags(machine!.delivery);
      expect(flags.slow === true).toBe(row.slow);
      expect(flags.queued === true).toBe(row.behindTurn);
      expect(flags.waitingForHost === true).toBe(row.heldForHost);
    }
  });

  test("every row of the table is decided here as it is written", () => {
    for (const row of table.transitions as { from: string; event: string; to?: string; refusal?: string }[]) {
      const machine = reach(row.from)!;
      const generation = attempt(machine.delivery) ?? 1;
      const event = [...INTENTS, ...answers(generation)].find((candidate) => candidate.event === row.event)!;
      const result = deliveryStep(machine, event);
      if (row.refusal !== undefined)
        expect(result, `${row.from} ${row.event}`).toEqual({ ok: false, refusal: row.refusal as never });
      else {
        expect(result.ok, `${row.from} ${row.event}`).toBe(true);
        if (result.ok) expect(deliveryKey(result.machine.delivery)).toBe(row.to!);
      }
    }
  });

  test("every sequence up to six writes one session/prompt at a time, only on a send", () => {
    let sequences = 0;
    const walk = (machine: DeliveryMachine, depth: number, out: boolean, taken: boolean) => {
      sequences += 1;
      if (depth === 6) return;
      const current = attempt(machine.delivery) ?? machine.issued;
      for (const event of [...INTENTS, ...answers(current), ...answers(current + 1)]) {
        const result = deliveryStep(machine, event);
        if (!result.ok) continue;
        const writes = result.effects.filter((effect) => effect.effect === "send_prompt").length;
        expect(writes).toBeLessThanOrEqual(1);
        if (writes === 1) {
          expect(["submit", "submit_behind_turn", "release"]).toContain(event.event);
          expect(out).toBe(false);
          expect(taken).toBe(false);
        }
        const nowOut = deliveryFacts(result.machine.delivery).inFlight;
        const after = result.machine.delivery;
        // Refused at its turn after acpmux took it: it never ran, so Retry may write it again.
        const nowTaken =
          after.state === "failed" && after.cause === "refused"
            ? false
            : taken || after.state === "delivered" || after.state === "read";
        walk(result.machine, depth + 1, nowOut, nowTaken);
      }
    };
    walk(DRAFT, 0, false, false);
    expect(sequences).toBeGreaterThan(1000);
  });
});

function attempt(delivery: DeliveryState): number | undefined {
  if (delivery.state === "draft") return undefined;
  if (delivery.state === "held") return delivery.hold.reason === "host_starting" ? delivery.hold.attempt : undefined;
  return delivery.attempt;
}

/// A machine in the state `key` names, reached from a draft by the table's own steps.
function reach(key: string): DeliveryMachine | undefined {
  const seen = new Set<string>();
  let frontier: DeliveryMachine[] = [DRAFT];
  for (let depth = 0; depth < 8 && frontier.length > 0; depth += 1) {
    const next: DeliveryMachine[] = [];
    for (const machine of frontier) {
      if (deliveryKey(machine.delivery) === key) return machine;
      const current = attempt(machine.delivery) ?? machine.issued;
      for (const event of [...INTENTS, ...answers(current)]) {
        const result = deliveryStep(machine, event);
        if (!result.ok) continue;
        const id = JSON.stringify(result.machine);
        if (seen.has(id)) continue;
        seen.add(id);
        next.push(result.machine);
      }
    }
    frontier = next;
  }
  return undefined;
}
