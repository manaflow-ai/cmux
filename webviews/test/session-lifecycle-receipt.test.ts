import { expect, test } from "bun:test";
import { sessionEntry } from "../src/agent-session/acpmux/sessionList";

const base = { sessionId: "session-1", name: "agent", status: "ready" };

test("sessionEntry preserves a valid explicit lifecycle receipt", () => {
  const entry = sessionEntry({
    ...base,
    lifecycleReceipt: { id: "receipt-1", sequence: 2, state: "running", source: "controller" },
  });
  expect(entry.lifecycleReceipt).toEqual({
    id: "receipt-1",
    sequence: 2,
    state: "running",
    source: "controller",
  });
});

test("sessionEntry drops malformed lifecycle evidence instead of inferring it", () => {
  expect(
    sessionEntry({
      ...base,
      lifecycleReceipt: { id: "receipt-1", sequence: 0, state: "running", source: "controller" },
    }).lifecycleReceipt,
  ).toBeUndefined();
  expect(
    sessionEntry({
      ...base,
      lifecycleReceipt: { id: "receipt-1", sequence: 1, state: "", source: "controller" },
    }).lifecycleReceipt,
  ).toBeUndefined();
  expect(
    sessionEntry({
      ...base,
      lifecycleReceipt: { id: "receipt-1", sequence: 1, state: "running" },
    }).lifecycleReceipt,
  ).toBeUndefined();
});
