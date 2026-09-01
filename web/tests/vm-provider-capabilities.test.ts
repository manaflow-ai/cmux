import { describe, expect, test } from "bun:test";

import { vmCapabilitiesFor } from "../services/vms/drivers";
import { vmUnsupportedCopy, vmUnsupportedOperationKey } from "../services/vms/vmErrorMessages";

describe("Cloud VM provider capabilities", () => {
  test("ports and stats follow the driver's methods, so clients can hide verbs that would only fail", () => {
    // Blaxel mints tokened preview URLs and reports stats; the other drivers do neither.
    const blaxel = vmCapabilitiesFor("blaxel");
    expect(blaxel.ports).toBe(true);
    expect(blaxel.stats).toBe(true);
    for (const provider of ["e2b", "freestyle", "daytona"] as const) {
      const capabilities = vmCapabilitiesFor(provider);
      expect(capabilities.ports).toBe(false);
      expect(capabilities.stats).toBe(false);
    }
  });

  test("an unsupported openPort/getStats maps to its own non-retryable copy", async () => {
    expect(vmUnsupportedOperationKey("openPort")).toBe("openPort");
    expect(vmUnsupportedOperationKey("getStats")).toBe("getStats");
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
