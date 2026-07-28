// SPDX-License-Identifier: GPL-3.0-or-later

import { describe, expect, it } from "bun:test";

import { HibernationRestoreGate } from "../src/restore-gate";
import type { Effect } from "../src/session";

const firstSnapshot: Effect = {
  kind: "send",
  to: "c-survivor",
  msg: { t: "resync" },
};
const laterPresence: Effect = {
  kind: "send",
  to: "c-survivor",
  msg: { t: "presence", participants: [] },
};

describe("hibernation restore gate", () => {
  it("holds every survivor delivery across fetch and alarm work until all pre-wake ACKs release", () => {
    const gate = new HibernationRestoreGate();
    gate.register("c-survivor", ["ack-before-wake-1", "ack-before-wake-2"]);

    expect(
      gate.route([
        firstSnapshot,
        { kind: "setAlarm", at: 123 },
      ]),
    ).toEqual([{ kind: "setAlarm", at: 123 }]);
    expect(gate.route([laterPresence])).toEqual([]);

    expect(gate.release("c-survivor", "unknown")).toEqual([]);
    expect(gate.release("other-socket", "ack-before-wake-1")).toEqual([]);
    expect(gate.release("c-survivor", "ack-before-wake-1")).toEqual([]);
    expect(gate.isWaiting("c-survivor")).toBe(true);
    expect(gate.release("c-survivor", "ack-before-wake-2")).toEqual([
      firstSnapshot,
      laterPresence,
    ]);
    expect(gate.isWaiting("c-survivor")).toBe(false);
  });

  it("does not gate a survivor with no pre-wake credit", () => {
    const gate = new HibernationRestoreGate();
    gate.register("c-survivor", []);

    expect(gate.route([firstSnapshot])).toEqual([firstSnapshot]);
    expect(gate.isWaiting("c-survivor")).toBe(false);
  });

  it("lets an authoritative close discard held deliveries immediately", () => {
    const gate = new HibernationRestoreGate();
    gate.register("c-survivor", ["ack-before-wake"]);
    expect(gate.route([firstSnapshot])).toEqual([]);

    const close: Effect = {
      kind: "close",
      to: "c-survivor",
      code: 4000,
      reason: "superseded",
    };
    expect(gate.route([close])).toEqual([close]);
    expect(gate.release("c-survivor", "ack-before-wake")).toEqual([]);
    expect(gate.isWaiting("c-survivor")).toBe(false);
  });
});
