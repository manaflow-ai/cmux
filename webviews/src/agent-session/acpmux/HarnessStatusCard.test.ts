import { expect, test } from "bun:test";
import type { AcpmuxSnapshot } from "./model";
import { authSourceLabel } from "./HarnessStatusCard";

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
