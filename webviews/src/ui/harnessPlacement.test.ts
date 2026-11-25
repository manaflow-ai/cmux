import { expect, test } from "bun:test";
import { resolveHarnessPlacement } from "./harnessPlacement";

test("fresh installs keep top symbols; old Debug choices remain until explicitly changed", () => {
  expect(resolveHarnessPlacement(undefined, undefined)).toBe("symbols");
  for (const choice of ["symbols", "left", "top", "compact"] as const) {
    expect(resolveHarnessPlacement(null, choice)).toBe(choice);
    expect(resolveHarnessPlacement(choice, "compact")).toBe(choice);
  }
  expect(resolveHarnessPlacement("symbols", "left")).toBe("symbols");
  expect(resolveHarnessPlacement("invalid", "left")).toBe("left");
  expect(resolveHarnessPlacement(null, "invalid")).toBe("symbols");
  expect(resolveHarnessPlacement("left", "compact", "top")).toBe("top");
});
