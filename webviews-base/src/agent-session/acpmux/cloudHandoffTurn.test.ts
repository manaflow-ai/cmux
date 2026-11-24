import { expect, test } from "bun:test";
import { handoffPromptId, handoffTurns, namesHandoffTurn, openHandoffTurn, turnOf } from "./cloudHandoffTurn";

test("a turn is a whole number from 1 that acpmux can read; anything else is none", () => {
  expect(turnOf({ turn: 1 })).toBe(1);
  expect(turnOf({ turn: 42 })).toBe(42);
  for (const turn of [0, -1, 1.5, "2", null, 1e15, Number.NaN]) expect(turnOf({ turn })).toBeUndefined();
  expect(turnOf(null)).toBeUndefined();
  expect(turnOf(undefined)).toBeUndefined();
});

test("the prompt id names the turn, then keeps the prompt's own id", () => {
  expect(handoffPromptId(3, "0b6f2c4e-1d2a-4f00-8a00-000000000001")).toBe(
    "handoff-3-0b6f2c4e-1d2a-4f00-8a00-000000000001",
  );
});

test("the app is asked for the session's turn; a refusal or no answer in time is none", async () => {
  const calls: [string, Record<string, unknown>][] = [];
  expect(await openHandoffTurn(async (method, params) => (calls.push([method, params]), { turn: 2 }), "s-1")).toBe(2);
  expect(calls).toEqual([["cloud.handoffTurn", { sessionId: "s-1" }]]);
  expect(
    await openHandoffTurn(async () => {
      throw Object.assign(new Error("running"), { code: "handoff.turn_running" });
    }, "s-1"),
  ).toBeUndefined();
  expect(await openHandoffTurn(() => new Promise(() => undefined), "s-1", 5)).toBeUndefined();
});

test("only an app that opens turns, for a chat on a Cloud machine, gets an ask", () => {
  const call = async () => ({ turn: 1 });
  expect(handoffTurns(call, { cloudHandoffs: true, cloudMachineID: "vm_1" })).toBeFunction();
  expect(handoffTurns(call, { cloudHandoffs: true })).toBeUndefined();
  expect(handoffTurns(call, { cloudMachineID: "vm_1" })).toBeUndefined();
  expect(handoffTurns(call, { cloudHandoffs: "yes", cloudMachineID: "vm_1" })).toBeUndefined();
  expect(handoffTurns(call, { cloudHandoffs: true, cloudMachineID: "" })).toBeUndefined();
});

test("only a whole turn prefix names a turn, as acpmux reads one", () => {
  expect(namesHandoffTurn("handoff-2-p-5")).toBe(true);
  expect(namesHandoffTurn("handoff-999999999999999-x")).toBe(true);
  expect(namesHandoffTurn("handoff-note")).toBe(false);
  expect(namesHandoffTurn("handoff-0-p")).toBe(false);
  expect(namesHandoffTurn("handoff-02-p")).toBe(false);
  expect(namesHandoffTurn("handoff-1000000000000000-p")).toBe(false);
  expect(namesHandoffTurn("handoff-3-")).toBe(false);
});
