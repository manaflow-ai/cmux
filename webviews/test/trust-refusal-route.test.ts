import { expect, test } from "bun:test";
import {
  routeCurrentTrustRefusal,
  routeOwnedTrustRefusal,
  type PendingTrustRefusal,
} from "../src/agent-session/acpmux/trustRefusalRoute";

for (const change of ["client", "generation", "session"] as const) {
  test(`a valid refusal waits for its new ${change} to render`, () => {
    const client = {};
    const before = { client, generation: 1, sessionId: "a", cancelEpoch: 0 };
    const current = {
      ...before,
      ...(change === "client" ? { client: {} } : {}),
      ...(change === "generation" ? { generation: 2 } : {}),
      ...(change === "session" ? { sessionId: "b" } : {}),
    };
    let delivered = 0;
    let queued: (() => void) | undefined;
    const deliver = () => (delivered++, true);
    routeCurrentTrustRefusal(current, before, deliver, () => {
      queued = () => routeCurrentTrustRefusal(current, current, deliver, () => expect.unreachable());
    });
    expect(delivered).toBe(0);
    expect(queued).toBeDefined();
    queued!();
    expect(delivered).toBe(1);
  });
}

test("a send rejected after Cancel cannot route through a fresh handler", () => {
  const owner = { client: {}, generation: 1, sessionId: "a", cancelEpoch: 0 };
  const current = { ...owner, cancelEpoch: 1 };
  const pending: { current: PendingTrustRefusal<object> | undefined } = { current: undefined };
  let delivered = 0;
  const routed = routeOwnedTrustRefusal(
    owner,
    current,
    current,
    pending,
    { reason: "trust.pending", cwd: "/project" },
    () => expect.unreachable("canceled prompt replayed"),
    () => (delivered++, true),
  );
  expect(routed).toBe(false);
  expect(delivered).toBe(0);
  expect(pending.current).toBeUndefined();
});

test("a new identical refusal replaces a canceled pending refusal during a render gap", () => {
  const old = { client: {}, generation: 1, sessionId: "a", cancelEpoch: 0 };
  const current = { ...old, cancelEpoch: 1 };
  const error = { reason: "trust.pending", cwd: "/project" };
  const pending: { current: PendingTrustRefusal<object> | undefined } = {
    current: { ...old, error, again: () => expect.unreachable("old retry survived") },
  };
  let resent = 0;
  const again = () => resent++;
  expect(
    routeOwnedTrustRefusal(current, current, old, pending, error, again, () =>
      expect.unreachable("stale render received refusal"),
    ),
  ).toBe(true);
  expect(pending.current?.cancelEpoch).toBe(1);
  routeCurrentTrustRefusal(
    pending.current!,
    current,
    () => {
      pending.current!.again!();
      return true;
    },
    () => expect.unreachable("new refusal stranded"),
  );
  expect(resent).toBe(1);
});

test("the current pending refusal keeps the fallback send's replay", () => {
  const owner = { client: {}, generation: 1, sessionId: "a", cancelEpoch: 1 };
  const error = { reason: "trust.pending", cwd: "/project" };
  const pending: { current: PendingTrustRefusal<object> | undefined } = { current: { ...owner, error } };
  const again = () => {};
  expect(
    routeOwnedTrustRefusal(owner, owner, undefined, pending, error, again, () =>
      expect.unreachable("render is not ready"),
    ),
  ).toBe(true);
  expect(pending.current?.again).toBe(again);
});
