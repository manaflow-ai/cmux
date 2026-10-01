import { expect, test } from "bun:test";
import { retryAgentStart, sessionName } from "../src/agent.ts";

test("an agent that closed while starting is retried; other errors are not", async () => {
  let calls = 0;
  const flaky = async () => {
    if (++calls < 3)
      throw new Error('acpmux ensure failed (1): {"message":"agent process closed"}');
    return "ok";
  };
  expect(await retryAgentStart(flaky)).toBe("ok");
  expect(calls).toBe(3);

  calls = 0;
  const broken = async () => {
    calls++;
    throw new Error("acpmux send failed (4): no session matches");
  };
  await expect(retryAgentStart(broken)).rejects.toThrow("no session");
  expect(calls).toBe(1);

  calls = 0;
  const alwaysClosed = async () => {
    calls++;
    throw new Error("agent process closed");
  };
  await expect(retryAgentStart(alwaysClosed)).rejects.toThrow("closed");
  expect(calls).toBe(3);
});

test("session names are stable per conversation", () => {
  expect(sessionName("23743aea-1111-2222-3333-444455556666")).toBe("mux-23743aea");
});
