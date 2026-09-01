import { describe, expect, test } from "bun:test";

import { assertVmCreateEnabled, vmCreateDisabledReason } from "../services/vms/config";
import { isVmCreateDisabledError } from "../services/vms/errors";

describe("VM create kill switch", () => {
  test("unset flags mean enabled", () => {
    expect(vmCreateDisabledReason("blaxel", {})).toBeNull();
    expect(vmCreateDisabledReason("freestyle", {})).toBeNull();
  });

  test("the global flag disables every provider", () => {
    expect(vmCreateDisabledReason("blaxel", { CMUX_VM_CREATE_ENABLED: "0" })).toContain("disabled");
    expect(vmCreateDisabledReason("freestyle", { CMUX_VM_CREATE_ENABLED: "off" })).toContain("disabled");
  });

  test("a provider flag disables only that provider", () => {
    const env = { CMUX_VM_BLAXEL_ENABLED: "false" };
    expect(vmCreateDisabledReason("blaxel", env)).toContain("blaxel");
    expect(vmCreateDisabledReason("freestyle", env)).toBeNull();
  });

  test("assertVmCreateEnabled throws the typed error", () => {
    try {
      assertVmCreateEnabled("e2b", { CMUX_VM_E2B_ENABLED: "0" });
      throw new Error("expected VmCreateDisabledError");
    } catch (err) {
      expect(isVmCreateDisabledError(err)).toBe(true);
    }
  });
});
