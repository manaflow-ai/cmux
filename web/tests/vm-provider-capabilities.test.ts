import { describe, expect, test } from "bun:test";

import { vmCapabilitiesFor, vmCapabilitiesOf } from "../services/vms/drivers";
import { MockVMProvider } from "../services/vms/drivers/mock";
import { VmOperationUnsupportedError, VmProviderOperationError } from "../services/vms/errors";
import { vmWorkflowErrorResponse } from "../services/vms/routeHelpers";
import { vmUnsupportedCopy, vmUnsupportedOperationKey } from "../services/vms/vmErrorMessages";

describe("Cloud VM provider capabilities", () => {
  test("ports and stats follow the driver's methods, so clients can hide verbs that would only fail", () => {
    const freestyle = vmCapabilitiesFor("freestyle");
    expect(freestyle.ports).toBe(true);
    expect(freestyle.stats).toBe(true);
    const minimal = vmCapabilitiesOf(new MockVMProvider());
    expect(minimal.ports).toBe(false);
    expect(minimal.stats).toBe(false);
    const disabled = vmCapabilitiesOf(new MockVMProvider({
      features: { ports: true, stats: true },
      capabilities: { ports: false, stats: false },
    }));
    expect(disabled.ports).toBe(false);
    expect(disabled.stats).toBe(false);
  });

  test("unsupported stats return a non-retryable 501 with stats-specific guidance", async () => {
    const response = await vmWorkflowErrorResponse(new VmProviderOperationError({
      provider: "freestyle",
      operation: "getStats",
      cause: new VmOperationUnsupportedError({ provider: "freestyle", operation: "getStats" }),
    }));
    expect(response!.status).toBe(501);
    expect(response!.headers.get("retry-after")).toBeNull();
    const payload = await response!.json();
    expect(payload).toMatchObject({
      error: "vm_operation_unsupported",
      retryable: false,
      details: { operation: "getStats", retryable: false },
    });
    expect(payload.message).toContain("CPU");
    expect(payload.action).toContain("cmux vm status");
  });

  test("an unsupported openPort/getStats maps to its own non-retryable copy", async () => {
    expect(vmUnsupportedOperationKey("openPort")).toBe("openPort");
    expect(vmUnsupportedOperationKey("getStats")).toBe("getStats");
    expect(vmUnsupportedOperationKey("get_stats")).toBe("getStats");
    expect(vmUnsupportedOperationKey("fork")).toBe("fork");
    expect(vmUnsupportedOperationKey("listVolumes")).toBe("default");
    for (const locale of ["en", "ja"] as const) {
      const ports = await vmUnsupportedCopy("openPort", locale);
      const stats = await vmUnsupportedCopy("getStats", locale);
      const fallback = await vmUnsupportedCopy("default", locale);
      expect(ports.message).not.toBe(fallback.message);
      expect(stats.message).not.toBe(fallback.message);
      expect(ports.action).toContain("cmux vm exec");
      expect(stats.action).toContain("cmux vm status");
    }
  });
});
