import { describe, expect, test } from "bun:test";
import { isOutsideScale, ratchetErrors } from "../scripts/check-design-tokens";

describe("design token ratchet", () => {
  test.each([
    ["padding", "var(--ds-space-1) 13px", true],
    ["padding", "var(--ds-space-1) 12px", false],
    ["gap", "var(--ds-space-2, 7px)", true],
    ["gap", "var(--ds-space-2, 8px)", false],
    ["height", "var(--ds-control-compact, 13px)", true],
    ["height", "var(--ds-control-compact, 24px)", false],
    ["gap", "var(--ds-space-2)", false],
    ["gap", "6px", true],
    ["gap", "8px", false],
  ] as const)("checks %s: %s", (property, value, outside) => {
    expect(isOutsideScale(property, value)).toBe(outside);
  });

  test("checks literals next to a token in calc", () => {
    expect(isOutsideScale("gap", "calc(var(--ds-space-2) + 2px)")).toBe(true);
    expect(isOutsideScale("gap", "calc(var(--ds-space-2) + 4px)")).toBe(false);
  });

  test("rejects a new declaration in a previously clean bucket", () => {
    const errors = ratchetErrors(new Map([["src.css\tspacing\tgap", 1]]), new Map());
    expect(errors).toHaveLength(1);
    expect(errors[0]).toContain("new design token violation");
  });

  test("requires a baseline shrink after a violation is removed", () => {
    const errors = ratchetErrors(new Map([["src.css\theight\theight", 1]]), new Map([["src.css\theight\theight", 2]]));
    expect(errors).toHaveLength(1);
    expect(errors[0]).toContain("baseline can shrink");
  });

  test("accepts an unchanged baseline", () => {
    expect(
      ratchetErrors(new Map([["src.css\tspacing\tpadding", 2]]), new Map([["src.css\tspacing\tpadding", 2]])),
    ).toEqual([]);
  });
});
