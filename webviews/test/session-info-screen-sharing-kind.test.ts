// l10n-allow-file: machine name fixtures.
import { expect, test } from "bun:test";
import { chatMachine } from "../src/agent-session/acpmux/chatMachine";
import { screenSharingKind } from "../src/agent-session/acpmux/session-info/screenSharing";

// Leo, 2026-11-18: "i should be able to see into any connected mac or linux machine".
test("a chat on a connected machine's own daemon offers View screen", () => {
  const machine = chatMachine({ machine: "studio", host: "install:studio" }, "cosmic", undefined, { origin: "remote" });
  expect(machine.kind).toBe("ssh");
  expect(screenSharingKind(machine)).toBe("view");
});

test("this Mac shares, a Cloud machine views, a peer's chat and an unnamed machine offer nothing", () => {
  expect(screenSharingKind({ kind: "local", name: "cosmic" })).toBe("share");
  expect(screenSharingKind({ kind: "cloud", name: "box" })).toBe("view");
  expect(screenSharingKind({ kind: "ssh", name: "huge" }, "huge")).toBeUndefined();
  expect(screenSharingKind({ kind: "ssh" })).toBeUndefined();
});
