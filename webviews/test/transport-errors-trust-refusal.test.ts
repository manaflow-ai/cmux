// acpmux refuses a request in a folder that has no Trust answer with `data.reason`
// `trust.pending` (or `trust.untrusted` after Not now) and an English message for its CLI:
// "trust.pending: answer the trust question for the folder first" (hub/pool/mod.rs,
// server/trust_gate.rs). The pane shows its own sentence for that reason, in the pane's language,
// and never the code or the daemon's words.
import { expect, test } from "bun:test";
import { translate } from "../src/agent-session/acpmux/i18n";
import { AcpmuxRpcError } from "../src/agent-session/acpmux/handoff/protocol";
import { HarnessSwitch } from "../src/agent-session/acpmux/harnessSwitch";
import { errorMessage, isHostRefusal } from "../src/agent-session/acpmux/transportErrors";

const pending = () =>
  new AcpmuxRpcError({
    code: -32602,
    message: "trust.pending: answer the trust question for the folder first",
    data: { reason: "trust.pending" },
  });
const untrusted = () =>
  new AcpmuxRpcError({
    code: -32602,
    message: "trust.untrusted: the user chose not to trust the folder (/Users/dev/app)",
    data: { reason: "trust.untrusted", cwd: "/Users/dev/app" },
  });

test("a trust refusal reads as the pane's sentence, not acpmux's code", () => {
  expect(errorMessage(pending())).toBe(translate("error.trustPending"));
  expect(errorMessage(untrusted())).toBe(translate("error.trustUntrusted"));
  for (const text of [errorMessage(pending()), errorMessage(untrusted())]) {
    expect(text).not.toContain("trust.");
    expect(text).not.toContain("the user chose");
  }
  // A trust refusal is acpmux's, not the pane host's: a queued pick does not report it as one.
  expect(isHostRefusal(pending())).toBe(false);
});

test("an error the pane has no words for still shows its own message", () => {
  expect(errorMessage(new Error("the agent exited"))).toBe("the agent exited");
});

// The switch boundary: a mode picked while a new chat starts goes out once it opens; acpmux
// refuses it because the folder still waits for its Trust answer, and the notice says so in words.
test("a queued mode pick refused for trust says to answer the trust question", async () => {
  const notices: string[] = [];
  const store = new HarnessSwitch();
  store.setHandlers({ notice: (text: string) => notices.push(text) });
  store.connect({
    turnRunning: () => false,
    shown: () => undefined,
    create: async () => "s1",
    leave: () => undefined,
    open: async (sessionId: string) => sessionId,
    send: async () => undefined,
    setModel: async () => undefined,
    setMode: async () => {
      throw pending();
    },
    setConfig: async () => undefined,
    discard: () => undefined,
    prewarm: () => undefined,
    prewarmSupported: () => false,
  } as never);
  const opened = store.switchTo("claude", "/Users/dev");
  store.pickMode("plan");
  expect(await opened).toBe("s1");
  await new Promise((done) => setTimeout(done, 0));
  expect(notices).toEqual([translate("switch.modeFailed", { mode: "plan", reason: translate("error.trustPending") })]);
  expect(notices[0]).not.toContain("trust.pending");
});
