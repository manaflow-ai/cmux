import { describe, expect, test } from "bun:test";
import { withOutcomeAsk } from "./outcomeAsk";

describe("withOutcomeAsk", () => {
  test("leaves an ask unchanged when the outcome is empty", () => {
    expect(withOutcomeAsk("Fix the parser", "  ")).toBe("Fix the parser");
  });

  test("appends a structured done-when section", () => {
    expect(withOutcomeAsk("Fix the parser", "the parser test passes\nno warnings")).toBe(
      "Fix the parser\n\nDone when:\nthe parser test passes\nno warnings",
    );
  });

  test("keeps a checkable outcome when the ask is empty", () => {
    expect(withOutcomeAsk("  ", "the check passes")).toBe("Done when:\nthe check passes");
  });
});
