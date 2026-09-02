import { describe, expect, test } from "bun:test";

import { assertVmCreateEnabled, vmCreateDisabledReason } from "../services/vms/config";
import { isVmCreateDisabledError } from "../services/vms/errors";

describe("VM create kill switch", () => {
  test("unset flags mean enabled", () => {
    expect(vmCreateDisabledReason("e2b", {})).toBeNull();
    expect(vmCreateDisabledReason("freestyle", {})).toBeNull();
  });

  test("the global flag disables every provider", () => {
    expect(vmCreateDisabledReason("e2b", { CMUX_VM_CREATE_ENABLED: "0" })).toContain("disabled");
    expect(vmCreateDisabledReason("freestyle", { CMUX_VM_CREATE_ENABLED: "off" })).toContain("disabled");
  });

  test("a provider flag disables only that provider", () => {
    const env = { CMUX_VM_FREESTYLE_ENABLED: "false" };
    expect(vmCreateDisabledReason("freestyle", env)).toContain("freestyle");
    expect(vmCreateDisabledReason("e2b", env)).toBeNull();
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
