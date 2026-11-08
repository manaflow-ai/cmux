// The native Session Info stepper and the page stepper share this optimistic request history.
// Two clicks can arrive before React paints the first one; the second must use the requested value,
// while a newer daemon value starts a new history from that value.
import { expect, test } from "bun:test";
import { nextSubagentLimitAsk } from "../src/agent-session/acpmux/session-info/native/limit";

test("rapid limit steps retain the optimistic value until the daemon advances", () => {
  const first = nextSubagentLimitAsk(undefined, "chat", 8, 9);
  const second = nextSubagentLimitAsk(first, "chat", 8, 10);
  expect(second).toEqual({ chat: "chat", over: [8, 9], value: 10 });

  const afterDaemon = nextSubagentLimitAsk(second, "chat", 10, 11);
  expect(afterDaemon).toEqual({ chat: "chat", over: [10], value: 11 });
});
