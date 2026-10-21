// A full-access refusal reads the same whether the pane's host or acpmux refused it. acpmux
// answers `-32000` with `data.reason: "full_access_off"` (start_mode.rs), which direct.ts keeps
// as `error.reason`; the pane's host answers `transport.full_access_off`. Both show the localized
// refusal, and both count as a host refusal a queued mode pick reports.
import { expect, test } from "bun:test";
import { translate } from "../src/agent-session/acpmux/i18n";
import { AcpmuxRpcError } from "../src/agent-session/acpmux/handoff/protocol";
import { HarnessSwitch } from "../src/agent-session/acpmux/harnessSwitch";
import { errorMessage, isHostRefusal } from "../src/agent-session/acpmux/transportErrors";

const daemon = Object.assign(new Error("full-access modes are turned off in cmux Settings"), {
  code: -32000,
  reason: "full_access_off",
});
const pane = Object.assign(new Error("refused"), { code: "transport.full_access_off" });

test("acpmux's full_access_off reads as the localized refusal", () => {
  expect(errorMessage(daemon)).toBe(translate("transport.fullAccessOff"));
  expect(errorMessage(pane)).toBe(translate("transport.fullAccessOff"));
});

test("both refusals count as host refusals; other failures do not", () => {
  expect(isHostRefusal(daemon)).toBe(true);
  expect(isHostRefusal(pane)).toBe(true);
  expect(isHostRefusal(Object.assign(new Error("x"), { code: -32000, reason: "trust.pending" }))).toBe(false);
  expect(isHostRefusal(new Error("x"))).toBe(false);
});

// The switch boundary: a mode picked while a new chat starts goes out once it opens; acpmux
// refuses it (the error as direct.ts rejects it) and the pane says why instead of staying quiet:
// the held-mode notice names the mode, and its reason is the localized refusal, not acpmux's English.
test("a queued full-access pick that acpmux refuses shows the refusal", async () => {
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
      throw new AcpmuxRpcError({
        code: -32000,
        message: "full-access modes are turned off in cmux Settings (sessions.allowFullAccess)",
        data: { reason: "full_access_off" },
      });
    },
    setConfig: async () => undefined,
    discard: () => undefined,
    prewarm: () => undefined,
    prewarmSupported: () => false,
  } as never);
  const opened = store.switchTo("claude", "/Users/dev");
  store.pickMode("bypassPermissions");
  expect(await opened).toBe("s1");
  await new Promise((done) => setTimeout(done, 0));
  expect(notices).toEqual([
    translate("switch.modeFailed", { mode: "bypassPermissions", reason: translate("transport.fullAccessOff") }),
  ]);
});

// The mode picker's warning color follows the same rule acpmux and the app enforce
// (cmux-tui/spec/full-access-modes.json): Codex's full-auto still asks, so it draws plain.
test("the picker's warning color follows the shared full-access rule", async () => {
  const { unrestricted } = await import("../src/agent-session/acpmux/ComposerPickers");
  for (const id of [
    "bypassPermissions",
    "agent-full-access",
    "danger-full-access",
    "yolo",
    "auto-approve",
    "skip-permissions",
  ])
    expect(unrestricted(id), id).toBe(true);
  for (const id of ["default", "agent", "read-only", "plan", "full-auto", "fullscreen", "full-context"])
    expect(unrestricted(id), id).toBe(false);
});
