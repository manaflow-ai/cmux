import { describe, expect, test } from "bun:test";
import { subagentModeName, subagentSetup } from "./subagentSetup";

describe("subagentSetup", () => {
  test("names the model, effort and the harness's own mode label", () => {
    expect(subagentSetup({ model: "claude-haiku-4-5", effort: "high", permissionMode: "plan" })).toBe(
      "claude-haiku-4-5 · high · Plan",
    );
  });
  test("leaves out the default effort and what the harness did not report", () => {
    expect(subagentSetup({ model: "sonnet", effort: "default" })).toBe("sonnet");
    expect(subagentSetup({})).toBeUndefined();
  });
  test("an unknown mode id shows as reported, never as Full access", () => {
    expect(subagentModeName("someNewMode")).toBe("someNewMode");
    expect(subagentModeName("bypassPermissions")).toBe("Bypass permissions");
    expect(subagentModeName("agent", "codex")).toBe("Ask for approval");
  });
});
