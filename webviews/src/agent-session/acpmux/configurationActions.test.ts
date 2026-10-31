import { describe, expect, test } from "bun:test";
import { configurationSessionMatches, effortPickOption, resolveEffortOption } from "./configurationActions";

describe("command-palette agent configuration actions", () => {
  test.each(["effort", "reasoning_effort", "thought_level"])("resolves the %s effort option", (id) => {
    const option = resolveEffortOption([
      { id: "mode", category: "mode" },
      { id, category: id === "thought_level" ? "thought_level" : undefined, currentValue: "medium" },
    ]);
    expect(option?.id).toBe(id);
  });

  test("an explicit config id wins when a harness names more than one effort-like option", () => {
    const option = resolveEffortOption(
      [
        { id: "reasoning_effort", currentValue: "medium" },
        { id: "effort", currentValue: "low" },
      ],
      "effort",
    );
    expect(option?.currentValue).toBe("low");
  });

  test("a queued action cannot cross a session switch", () => {
    expect(configurationSessionMatches("session-a", "session-a")).toBe(true);
    expect(configurationSessionMatches("session-a", "session-b")).toBe(false);
    expect(configurationSessionMatches(undefined, "session-b")).toBe(true);
  });

  test("an effort pick goes to the option the session names, or is only held before it names one", () => {
    // The session reports its effort option: the pick is live, on that option.
    expect(effortPickOption([{ id: "reasoning_effort", currentValue: "medium" }])).toEqual({
      id: "reasoning_effort",
      current: "medium",
      live: true,
    });
    // A New Tab before its session: no options, the picker's generic id, held for the session.
    expect(effortPickOption(undefined, "effort")).toEqual({ id: "effort", live: false });
    expect(effortPickOption([], "effort")).toEqual({ id: "effort", live: false });
    // Nothing named and no id sent: there is nothing to pick.
    expect(effortPickOption(undefined)).toBeUndefined();
  });
});
