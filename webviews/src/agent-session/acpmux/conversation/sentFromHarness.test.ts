// l10n-allow-file: harness names and record fixtures.
import { expect, test } from "bun:test";
import { sentFrom } from "./sentFromHarness";

const desktop = {
  harness: "claude-code",
  entrypoint: "claude-desktop",
  sessionId: "8f0c2b7e",
  hostSessionId: "local_01HZYX",
  selfReported: true,
};

test("a Claude desktop send the daemon saw under Claude.app is confirmed", () => {
  const from = sentFrom({
    promptId: "p1",
    claimed: desktop,
    checked: { harness: "claude-code", app: "Claude.app", signedBy: "Developer ID Application: Anthropic" },
  });
  expect(from).toEqual({
    promptId: "p1",
    harness: "claude-code",
    label: "Claude desktop",
    sessionId: "8f0c2b7e",
    hostSessionId: "local_01HZYX",
    checked: { harness: "claude-code", app: "Claude.app", signedBy: "Developer ID Application: Anthropic" },
    confirmed: true,
  });
});

test("a Claude desktop send the daemon found only as Claude.app, with no harness binary, is confirmed", () => {
  const from = sentFrom({ promptId: "p", claimed: desktop, checked: { app: "Claude.app" } });
  expect(from?.label).toBe("Claude desktop");
  expect(from?.confirmed).toBe(true);
  // Only for a desktop claim: a Codex claim is not confirmed by Claude.app.
  const codex = { harness: "codex", selfReported: true };
  expect(sentFrom({ promptId: "p", claimed: codex, checked: { app: "Claude.app" } })?.confirmed).toBe(false);
});

test("a claim the daemon could not check, or found otherwise, stays self-reported", () => {
  expect(sentFrom({ promptId: "p", claimed: desktop })?.confirmed).toBe(false);
  // A shell in a terminal that set Claude desktop's variables itself.
  const forged = sentFrom({ promptId: "p", claimed: desktop, checked: { app: "Terminal.app" } });
  expect(forged?.label).toBe("Claude desktop");
  expect(forged?.confirmed).toBe(false);
  // Claude Code found, but not under Claude.app: a desktop claim needs the app.
  expect(sentFrom({ promptId: "p", claimed: desktop, checked: { harness: "claude-code" } })?.confirmed).toBe(false);
});

test("each harness reads by its own name", () => {
  const label = (claimed: object) => sentFrom({ promptId: "p", claimed })?.label;
  expect(label({ harness: "claude-code", entrypoint: "cli" })).toBe("Claude Code");
  expect(label({ harness: "claude-code", entrypoint: "sdk-ts" })).toBe("Claude Agent SDK");
  expect(label({ harness: "codex", sessionId: "t" })).toBe("Codex");
  expect(label({ harness: "Duet", app: "Duet.app" })).toBe("Duet");
  expect(label({ harness: "claude-ai", source: "mcp" })).toBe("claude-ai");
});

test("a record with no prompt id, no harness or odd fields draws nothing it cannot show", () => {
  expect(sentFrom({ claimed: desktop })).toBeUndefined();
  expect(sentFrom({ promptId: "p", claimed: { entrypoint: "cli" } })).toBeUndefined();
  expect(sentFrom("claude")).toBeUndefined();
  const odd = sentFrom({ promptId: "p", claimed: { harness: "codex", sessionId: "a\u0007b" }, checked: { app: 3 } });
  expect(odd).toEqual({ promptId: "p", harness: "codex", label: "Codex", confirmed: false });
});

test("a claim naming Claude.app is confirmed only when the daemon found Claude.app", () => {
  // From the process chain, not an entrypoint: the claim names the app it says it ran under.
  const byApp = { harness: "claude-code", app: "Claude.app", selfReported: true };
  const underTerminal = sentFrom({
    promptId: "p",
    claimed: byApp,
    checked: { harness: "claude-code", app: "Terminal.app" },
  });
  expect(underTerminal?.label).toBe("Claude desktop");
  expect(underTerminal?.confirmed).toBe(false);
  expect(
    sentFrom({ promptId: "p", claimed: byApp, checked: { harness: "claude-code", app: "Claude.app" } })?.confirmed,
  ).toBe(true);
});

// Leo, 2026-11-11: "generally the "unverified sender" things should be more verified". Our outbox
// relay, run by the python Xcode ships, claimed "Xcode" from an older CLI; the daemon now names the
// program it found, and the claim is only said.
test("an unconfirmed claim with a program the daemon found names that program, never the claim", () => {
  const from = sentFrom({
    promptId: "p",
    claimed: { harness: "Xcode", app: "Xcode.app", source: "process", selfReported: true },
    checked: { peerPid: 7, program: "outbox_relay.py", programPath: "/t/outbox_relay.py", interpreter: "Python" },
  });
  expect(from).toEqual({
    promptId: "p",
    harness: "Xcode",
    label: "outbox_relay.py",
    claimedLabel: "Xcode",
    checked: { program: "outbox_relay.py" },
    confirmed: false,
  });
  // A confirmed claim keeps its own label, the program beside it.
  const desktopFound = sentFrom({
    promptId: "p",
    claimed: desktop,
    checked: { harness: "claude-code", app: "Claude.app", program: "zsh" },
  });
  expect(desktopFound?.label).toBe("Claude desktop");
  expect(desktopFound?.claimedLabel).toBeUndefined();
  expect(desktopFound?.confirmed).toBe(true);
  // An old record with no program: as before.
  expect(sentFrom({ promptId: "p", claimed: desktop, checked: { app: "Terminal.app" } })?.label).toBe(
    "Claude desktop",
  );
});
