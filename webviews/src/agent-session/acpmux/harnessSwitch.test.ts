import { expect, test } from "bun:test";
import { HarnessSwitch, type SwitchPort } from "./harnessSwitch";

const trustRefusal = Object.assign(new Error("trust.pending"), {
  reason: "trust.pending",
  cwd: "/work/untrusted",
});

function trustRefusingPort(): SwitchPort {
  return {
    turnRunning: () => false,
    shown: () => undefined,
    create: async () => {
      throw trustRefusal;
    },
    leave: () => undefined,
    open: async () => undefined,
    send: async () => undefined,
    setModel: async () => undefined,
    setMode: async () => undefined,
    setConfig: async () => undefined,
    discard: () => undefined,
    prewarm: () => undefined,
    prewarmSupported: () => false,
  };
}

test("a blank deferred Return can leave New Tab while HarnessSwitch holds trust", async () => {
  const harnessSwitch = new HarnessSwitch();
  harnessSwitch.connect(trustRefusingPort());

  // This is the chat.new promise the New Tab submit observes. It must remain pending until Trust;
  // the blank-return branch clears the page synchronously rather than waiting for this promise.
  let settled = false;
  const started = harnessSwitch.switchTo("claude", "/work/untrusted", { deferred: true });
  void started.then(
    () => {
      settled = true;
    },
    () => {
      settled = true;
    },
  );
  await Promise.resolve();
  await Promise.resolve();

  expect(settled).toBe(false);
  expect(harnessSwitch.view().intent).toMatchObject({
    phase: "trust",
    harness: "claude",
    cwd: "/work/untrusted",
    shown: false,
  });
});

test("cancel drops a trust-waiting intent before folder-free recovery starts", async () => {
  const harnessSwitch = new HarnessSwitch();
  harnessSwitch.connect(trustRefusingPort());
  const restored: string[] = [];
  harnessSwitch.setHandlers({ restore: (text) => restored.push(text) });
  void harnessSwitch.switchTo("claude", "/work/untrusted");
  await Promise.resolve();
  await Promise.resolve();
  expect(harnessSwitch.view().intent?.phase).toBe("trust");
  harnessSwitch.cancel();
  expect(harnessSwitch.view().intent).toBeUndefined();
});
