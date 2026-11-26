import { describe, expect, test } from "bun:test";

import { createOptionPolicy } from "../app/api/vm/route";

describe("createOptionPolicy", () => {
  test("home-volume flags on a provider without home volumes are ignored, not rejected", () => {
    // What every shipped `cmux vm new` sends on the default create.
    const policy = createOptionPolicy(
      { sizing: true, persistentHome: false },
      { persistentHome: true, perMachineHome: true, kind: "desktop" },
    );
    expect(policy).toEqual({ kind: "accept", ignoredFields: ["persistentHome", "perMachineHome"] });
  });

  test("home-volume flags on a provider with home volumes pass through untouched", () => {
    expect(createOptionPolicy({ sizing: true, persistentHome: true }, { perMachineHome: true }))
      .toEqual({ kind: "accept", ignoredFields: [] });
  });

  test("a size on a provider without sizing is still rejected", () => {
    expect(createOptionPolicy({ sizing: false, persistentHome: false }, { memoryMb: 8192, persistentHome: true }))
      .toEqual({ kind: "reject", operation: "sizing", field: "memoryMb" });
  });

  test("a bare create has nothing to ignore", () => {
    expect(createOptionPolicy({ sizing: false, persistentHome: false }, {}))
      .toEqual({ kind: "accept", ignoredFields: [] });
  });
});
