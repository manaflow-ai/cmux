import { expect, test } from "bun:test";
import type { AcpmuxSnapshot } from "./model";
import { authSourceLabel, statusCardCopyText } from "./HarnessStatusCard";

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
