import { expect, test } from "bun:test";
import { acknowledgeDelivery, deliveryUsage, emptyDeliveryState, prepareDelivery } from "../src/delivery";
import { ResponseSchema } from "../src/contracts/responses";

const reply = { schemaId: "operation.completed.v1", requestId: "r", revision: 1 } as const;

test("actual output creates a checkpoint, idle state creates no heartbeat", () => {
  let state = emptyDeliveryState();
  expect(deliveryUsage(state)).toEqual({ bytes: 0, messages: 0 });
  for (let i = 0; i < 16; i++) {
    const next = prepareDelivery(state, reply);
    const wire = ResponseSchema.parse(JSON.parse(next.text));
    expect(wire.deliveryReceipt !== undefined).toBe(i === 15);
    if (wire.deliveryReceipt) expect(Object.keys(JSON.parse(next.text)).at(-1)).toBe("deliveryReceipt");
    state = next.state;
  }
  expect(deliveryUsage(state).messages).toBe(16);
  const point = state.checkpoints[0]!;
  expect(() => acknowledgeDelivery(state, point.sequence, "guessed-token")).toThrow("invalid_request");
  expect(() => acknowledgeDelivery(state, point.sequence + 1, point.token)).toThrow("invalid_request");
  const cleared = acknowledgeDelivery(state, point.sequence, point.token);
  expect(deliveryUsage(cleared)).toEqual({ bytes: 0, messages: 0 });
  expect(acknowledgeDelivery(cleared, point.sequence, point.token)).toBe(cleared);
});

test("a stopped reader reaches the accepted message bound and cannot grow the buffer", () => {
  let state = emptyDeliveryState();
  for (let i = 0; i < 1024; i++) state = prepareDelivery(state, reply).state;
  expect(deliveryUsage(state).messages).toBe(1024);
  expect(() => prepareDelivery(state, reply)).toThrow("slow_consumer");
  expect(JSON.stringify(state).length).toBeLessThan(16_384);
});

test("acknowledging a checkpoint leaves subsequent output charged", () => {
  let state = emptyDeliveryState();
  for (let i = 0; i < 17; i++) state = prepareDelivery(state, reply).state;
  const point = state.checkpoints[0]!;
  const acknowledged = acknowledgeDelivery(state, point.sequence, point.token);
  expect(deliveryUsage(acknowledged).messages).toBe(1);
  expect(deliveryUsage(acknowledged).bytes).toBeGreaterThan(0);
});
