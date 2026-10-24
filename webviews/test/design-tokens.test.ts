import { describe, expect, test } from "bun:test";
import { ratchetErrors } from "../scripts/check-design-tokens";

describe("design token ratchet", () => {
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
