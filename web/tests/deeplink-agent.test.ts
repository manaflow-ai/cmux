import { describe, expect, test } from "bun:test";
import {
  agentNativeHref,
  invalidAgentParams,
} from "../app/[locale]/(landing)/deeplink/[kind]/deeplink-agent";

describe("agent deeplink fallback", () => {
  test("builds the path-form native URL cmux NEXT parses", () => {
    expect(
      agentNativeHref({
        harness: "claude",
        session: "abc-123",
        host: "big-red",
        name: "Rivetmoss",
      }),
    ).toBe("cmux://agent/claude/abc-123?host=big-red&name=Rivetmoss");
  });

  test("omits absent hints", () => {
    expect(agentNativeHref({ harness: "codex", session: "s.1_x" })).toBe(
      "cmux://agent/codex/s.1_x",
    );
    expect(
      agentNativeHref({ harness: "codex", session: "s1", name: "Lane" }),
    ).toBe("cmux://agent/codex/s1?name=Lane");
  });

  test("accepts valid params", () => {
    expect(
      invalidAgentParams({
        harness: "claude-code",
        session: "a".repeat(200),
        host: "h".repeat(64),
        name: "N.a_m-e",
      }),
    ).toEqual([]);
  });

  test.each([
    ["harness", { harness: "Claude", session: "s" }],
    ["harness", { harness: "a".repeat(33), session: "s" }],
    ["harness", { harness: "claude/x", session: "s" }],
    ["session", { harness: "claude", session: "a".repeat(201) }],
    ["session", { harness: "claude", session: "../etc" }],
    ["session", { harness: "claude", session: "a b" }],
    ["session", { harness: "claude", session: "<script>" }],
    ["host", { harness: "claude", session: "s", host: "evil.com/x" }],
    ["host", { harness: "claude", session: "s", host: "h".repeat(65) }],
    ["host", { harness: "claude", session: "s", host: "" }],
    ["name", { harness: "claude", session: "s", name: "two words" }],
    ["name", { harness: "claude", session: "s", name: "n".repeat(65) }],
  ])("rejects bad %s", (param, params) => {
    expect(invalidAgentParams(params)).toContain(param);
  });

  test("does not build a native URL from invalid params", () => {
    expect(
      agentNativeHref({ harness: "claude", session: "s?x=1#y" }),
    ).toBeNull();
    expect(
      agentNativeHref({ harness: "claude", session: "s", host: "a@b" }),
    ).toBeNull();
    expect(agentNativeHref({ harness: "claude" })).toBeNull();
    expect(
      agentNativeHref({ harness: ["claude", "codex"], session: "s" }),
    ).toBeNull();
  });
});
