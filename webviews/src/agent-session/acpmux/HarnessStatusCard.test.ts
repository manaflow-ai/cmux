import { expect, test } from "bun:test";
import type { AcpmuxSnapshot } from "./model";
import { authSourceLabel, provenanceFields, statusCardCopyText } from "./harnessStatusCardModel";

const summary = (agentInfo: Record<string, unknown>, authSource?: string): NonNullable<AcpmuxSnapshot["summary"]> => ({
  sessionId: "test-session",
  agentInfo,
  authSource,
});

test("status displays only a named authSource field", () => {
  expect(authSourceLabel(summary({ auth: "Bearer super-secret-token" }))).toBe("Not reported");
  expect(authSourceLabel(summary({ auth: "Bearer super-secret-token", authSource: "Managed login" }))).toBe(
    "Managed login",
  );
  expect(authSourceLabel(summary({}, "Environment route"))).toBe("Environment route");
});

test("status card copy all is plain label-value lines", () => {
  expect(
    statusCardCopyText([
      ["Session", "session-123"],
      ["CWD", "/Users/leo/cmux"],
      ["Model", "Not reported"],
    ]),
  ).toBe("Session: session-123\nCWD: /Users/leo/cmux\nModel: Not reported");
});

test("provenance rows render acpmux's fixed words, with sanitized names", () => {
  const rows = provenanceFields({
    sessionId: "s",
    provenance: {
      machine: "air-blue",
      account: "environment",
      accountName: ".codex-work",
      credential: "profile",
      config: "profileFile",
      configName: "codex-work.toml",
      eligibility: "notEntitled",
    },
  });
  expect(rows).toEqual([
    ["Account", "Login shell's account home (.codex-work)"],
    ["Credential owner", "Harness profile"],
    ["Config source", "Profile file (codex-work.toml)"],
    ["Eligibility", "Signed in, but this account lacks the workspace or feature"],
  ]);
});

test("provenance distinguishes expired and signed out from not entitled, and unknown reads plainly", () => {
  const eligibility = (value: string) =>
    provenanceFields({ sessionId: "s", provenance: { eligibility: value } as never })[3]?.[1];
  expect(eligibility("expired")).toBe("Sign-in expired");
  expect(eligibility("signInNeeded")).toBe("Sign-in needed");
  expect(eligibility("unknown")).toBe("Not verified");
  // A word acpmux does not send never renders as raw text.
  expect(eligibility("Bearer sk-secret")).toBe("Not reported");
  const rows = provenanceFields({ sessionId: "s", provenance: { account: "default", credential: "unknown" } });
  expect(rows[0]?.[1]).toBe("Default account home");
  expect(rows[1]?.[1]).toBe("Not reported");
  expect(provenanceFields({ sessionId: "s" })).toEqual([]);
});
