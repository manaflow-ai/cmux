import { describe, expect, test } from "bun:test";

import { vmCapabilitiesFor } from "../services/vms/drivers";

// Capabilities are per machine, not just per provider: Freestyle spans a legacy
// platform (fork works) and a beta platform whose API has no fork at all, so a
// beta machine must not advertise Fork even though `FreestyleProvider.fork` exists.
describe("vmCapabilitiesFor", () => {
  test("freestyle legacy machines can snapshot, restore and fork", () => {
    expect(vmCapabilitiesFor("freestyle", "abc123def456ghij7890")).toEqual({
      snapshot: true,
      restore: true,
      fork: true,
    });
  });

  test("freestyle beta machines cannot fork", () => {
    expect(vmCapabilitiesFor("freestyle", `vm-${"a".repeat(32)}`)).toEqual({
      snapshot: true,
      restore: true,
      fork: false,
    });
  });

  test("the provider-level answer is unchanged when no machine is named", () => {
    expect(vmCapabilitiesFor("freestyle").fork).toBe(true);
  });

  test("blaxel declares every optional verb unsupported", () => {
    expect(vmCapabilitiesFor("blaxel", "vivid-newt")).toEqual({
      snapshot: false,
      restore: false,
      fork: false,
    });
  });
});
