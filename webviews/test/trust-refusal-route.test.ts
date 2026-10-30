import { expect, test } from "bun:test";
import { routeCurrentTrustRefusal } from "../src/agent-session/acpmux/trustRefusalRoute";

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
