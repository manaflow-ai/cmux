import { describe, expect, test } from "bun:test";
import { buildResumeCommand, normalizeAdapterId } from "../src/adapters";

describe("agent adapters", () => {
  test("normalizes supported adapter names", () => {
    expect(normalizeAdapterId("Claude Code")).toBe("claude");
    expect(normalizeAdapterId("open-code")).toBe("opencode");
    expect(normalizeAdapterId("Pi Coding Agent")).toBe("pi");
  });

  test("builds resume commands for each supported adapter", () => {
    expect(buildResumeCommand({ adapter: "claude", sessionId: "claude-1" })).toBe("claude --resume claude-1");
    expect(buildResumeCommand({ adapter: "codex", sessionId: "codex-1", cwd: "/tmp/team repo" })).toBe(
      "cd '/tmp/team repo' && codex resume codex-1",
    );
    expect(buildResumeCommand({ adapter: "opencode", sessionId: "opencode-1", model: "anthropic/claude" })).toBe(
      "opencode --session opencode-1 -m anthropic/claude",
    );
    expect(buildResumeCommand({ adapter: "pi", sessionId: "pi-1", thinking: "high" })).toBe(
      "pi --session pi-1 --thinking high",
    );
  });
});
