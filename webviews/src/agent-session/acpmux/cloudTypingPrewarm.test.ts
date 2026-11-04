import { expect, test } from "bun:test";
import { CLOUD_TYPING_PREWARM_REFRESH_MS, CloudTypingPrewarm } from "./cloudTypingPrewarm";

function harness() {
  let now = 0;
  const calls: string[] = [];
  const prewarm = new CloudTypingPrewarm({ prewarm: (machineID) => calls.push(machineID) }, () => now);
  return { prewarm, calls, advance: (ms: number) => (now += ms) };
}

test("first Cloud keystroke hints only the shown machine", () => {
  const { prewarm, calls } = harness();
  prewarm.typed("h", { machineID: "cloud-a", sessionID: "chat-a" });
  prewarm.typed("he", { machineID: "cloud-a", sessionID: "chat-a" });
  expect(calls).toEqual(["cloud-a"]);
});

test("typing refreshes after the dedupe window", () => {
  const { prewarm, calls, advance } = harness();
  const target = { machineID: "cloud-a", sessionID: "chat-a" };
  prewarm.typed("h", target);
  advance(CLOUD_TYPING_PREWARM_REFRESH_MS);
  prewarm.typed("hello", target);
  expect(calls).toEqual(["cloud-a", "cloud-a"]);
});

test("a new chat on the same machine gets its own first hint", () => {
  const { prewarm, calls } = harness();
  prewarm.typed("h", { machineID: "cloud-a", sessionID: "chat-a" });
  prewarm.typed("h", { machineID: "cloud-a", sessionID: "chat-b" });
  expect(calls).toEqual(["cloud-a", "cloud-a"]);
});

test("empty and whitespace drafts do not wake, and reset allows a new hint", () => {
  const { prewarm, calls } = harness();
  const target = { machineID: "cloud-a", sessionID: "chat-a" };
  prewarm.typed(" ", target);
  prewarm.typed("x", target);
  prewarm.reset();
  prewarm.typed("y", target);
  expect(calls).toEqual(["cloud-a", "cloud-a"]);
});

test("a native failure is isolated from typing", () => {
  const prewarm = new CloudTypingPrewarm({
    prewarm: () => {
      throw new Error("offline");
    },
  });
  expect(() => prewarm.typed("x", { machineID: "cloud-a" })).not.toThrow();
});

test("fresh and missing-session drafts can wake an explicitly selected machine", () => {
  const { prewarm, calls } = harness();
  prewarm.typed("h", { machineID: "cloud-draft" });
  prewarm.typed("he", { machineID: "cloud-draft" });
  expect(calls).toEqual(["cloud-draft"]);
});
