import { expect, test } from "bun:test";
import { retryAgentStart, sessionName } from "../src/agent.ts";

/** The error a promise rejects with (Bun's types do not mark `rejects` as awaitable). */
async function rejection(promise: Promise<unknown>): Promise<string> {
  try {
    await promise;
  } catch (error) {
    return String(error);
  }
  throw new Error("expected a rejection");
}

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
  expect(await rejection(retryAgentStart(broken))).toContain("no session");
  expect(calls).toBe(1);

  calls = 0;
  const alwaysClosed = async () => {
    calls++;
    throw new Error("agent process closed");
  };
  expect(await rejection(retryAgentStart(alwaysClosed))).toContain("closed");
  expect(calls).toBe(3);
});

test("session names are stable per conversation", () => {
  expect(sessionName("23743aea-1111-2222-3333-444455556666")).toBe("mux-23743aea");
});
