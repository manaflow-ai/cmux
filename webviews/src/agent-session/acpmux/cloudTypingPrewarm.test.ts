import { expect, test } from "bun:test";
import {
  CLOUD_TYPING_PREWARM_REFRESH_MS,
  CloudTypingPrewarm,
  cloudIdentityKept,
  cloudTypingMachineID,
} from "./cloudTypingPrewarm";

function harness() {
  let now = 0;
  const calls: string[] = [];
  const prewarm = new CloudTypingPrewarm(
    {
      prewarm: (machineID) => {
        calls.push(machineID);
        return true;
      },
    },
    () => now,
  );
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

test("a declined native hint can retry on the next edit", async () => {
  let loaded = false;
  const calls: string[] = [];
  const prewarm = new CloudTypingPrewarm(
    {
      prewarm: async (machineID) => {
        calls.push(machineID);
        return loaded;
      },
    },
    () => 0,
  );
  const target = { machineID: "cloud-a", sessionID: "chat-a" };
  prewarm.typed("h", target);
  await Promise.resolve();
  loaded = true;
  prewarm.typed("he", target);
  await Promise.resolve();
  prewarm.typed("hel", target);
  expect(calls).toEqual(["cloud-a", "cloud-a"]);
});

test("pending hints dedupe and late declines cannot clear a new target", async () => {
  let finishFirst!: (accepted: boolean) => void;
  const calls: string[] = [];
  const prewarm = new CloudTypingPrewarm(
    {
      prewarm: (machineID) => {
        calls.push(machineID);
        if (machineID === "cloud-a") {
          return new Promise<boolean>((resolve) => {
            finishFirst = resolve;
          });
        }
        return true;
      },
    },
    () => 0,
  );
  prewarm.typed("h", { machineID: "cloud-a" });
  prewarm.typed("he", { machineID: "cloud-a" });
  prewarm.typed("h", { machineID: "cloud-b" });
  finishFirst(false);
  await Promise.resolve();
  prewarm.typed("he", { machineID: "cloud-b" });
  expect(calls).toEqual(["cloud-a", "cloud-b"]);
});

test("a rejected native request allows the next edit to retry", async () => {
  let attempts = 0;
  const prewarm = new CloudTypingPrewarm(
    {
      prewarm: async () => {
        attempts += 1;
        throw new Error("offline");
      },
    },
    () => 0,
  );
  prewarm.typed("h", { machineID: "cloud-a" });
  await Promise.resolve();
  prewarm.typed("he", { machineID: "cloud-a" });
  await Promise.resolve();
  expect(attempts).toBe(2);
});

test("an explicit local choice suppresses a previous Cloud identity until the chat changes", () => {
  expect(cloudTypingMachineID(undefined, "previous-cloud")).toBe("previous-cloud");
  expect(cloudTypingMachineID("picked-cloud", "previous-cloud")).toBe("picked-cloud");
  expect(cloudTypingMachineID(null, "previous-cloud")).toBeUndefined();
  expect(cloudTypingMachineID(undefined)).toBeUndefined();
});

test("a handshake's Cloud identity stays with its chat, not the next draft or chat in the pane", () => {
  // A send from a fresh Cloud draft adopts its new session: the identity is that chat's.
  expect(cloudIdentityKept({ generation: 1 }, { session: "chat-a", generation: 1 })).toBe(true);
  expect(cloudIdentityKept({ session: "chat-a", generation: 1 }, { session: "chat-a", generation: 1 })).toBe(true);
  // Leaving the Cloud chat for a New Tab draft or another chat drops it until that page's handshake.
  expect(cloudIdentityKept({ session: "chat-a", generation: 1 }, { generation: 1 })).toBe(false);
  expect(cloudIdentityKept({ session: "chat-a", generation: 1 }, { session: "chat-b", generation: 1 })).toBe(false);
  expect(cloudIdentityKept({ generation: 1 }, { generation: 2 })).toBe(false);
  // An unbound identity never names the machine a fresh local draft's first edit hints.
  expect(cloudTypingMachineID(undefined, undefined)).toBeUndefined();
});
