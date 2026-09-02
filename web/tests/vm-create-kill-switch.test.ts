import { describe, expect, test } from "bun:test";

import { assertVmCreateEnabled, vmCreateDisabledReason } from "../services/vms/config";
import { isVmCreateDisabledError } from "../services/vms/errors";

describe("VM create kill switch", () => {
  test("unset flags mean enabled", () => {
    expect(vmCreateDisabledReason("freestyle", {})).toBeNull();
  });

  test("the global flag disables creation", () => {
    expect(vmCreateDisabledReason("freestyle", { CMUX_VM_CREATE_ENABLED: "0" })).toContain("disabled");
    expect(vmCreateDisabledReason("freestyle", { CMUX_VM_CREATE_ENABLED: "off" })).toContain("disabled");
  });

  test("the provider flag names the provider it disabled", () => {
    const env = { CMUX_VM_FREESTYLE_ENABLED: "false" };
    expect(vmCreateDisabledReason("freestyle", env)).toContain("freestyle");
  });

  test("an unrelated env flag does not disable creation", () => {
    expect(vmCreateDisabledReason("freestyle", { CMUX_VM_SOME_OTHER_FLAG: "0" })).toBeNull();
  });

  test("assertVmCreateEnabled throws the typed error", () => {
    try {
      assertVmCreateEnabled("freestyle", { CMUX_VM_FREESTYLE_ENABLED: "0" });
      throw new Error("expected VmCreateDisabledError");
    } catch (err) {
      expect(isVmCreateDisabledError(err)).toBe(true);
    }
  });
});
