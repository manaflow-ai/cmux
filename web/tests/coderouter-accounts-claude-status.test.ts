import { describe, expect, test } from "bun:test";
import { claudeStatusAccount } from "../services/coderouter/usage";

describe("coderouter account status includes Claude accounts", () => {
  test("a Claude upstream account appears as a `claude` provider row without secrets", () => {
    const row = claudeStatusAccount({
      id: "a10a7f6a-27b5-4e36-9a71-005d2c0539df",
      kind: "anthropic_oauth",
      label: "Claude Code",
      visibility: "private",
      createdBy: "user-1",
      identifier: "sk-ant-oat01-…9xYz",
      region: null,
      modelIds: {},
      state: "active",
      cooldownUntil: null,
      lastFailureCode: null,
      lastUsedAt: null,
      createdAt: "2026-10-05T11:00:00.000Z",
      updatedAt: "2026-10-05T11:00:00.000Z",
    });
    expect(row).toEqual({
      id: "a10a7f6a-27b5-4e36-9a71-005d2c0539df",
      provider: "claude",
      kind: "anthropic_oauth",
      label: "Claude Code",
      identifier: "sk-ant-oat01-…9xYz",
      state: "active",
      cooldownUntil: null,
      lastFailureCode: null,
      visibility: "private",
      createdBy: "user-1",
      activeSessions: 0,
    });
  });
});
