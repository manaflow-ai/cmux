import { describe, expect, test } from "bun:test";
import { runCrossHostVerification } from "../scripts/verify-cross-host-broker";

describe("cross-host broker runtime verification", () => {
  test("passes Huge Blue, Freestyle, and Mac mini fixture lanes", async () => {
    const report = await runCrossHostVerification({ env: {}, live: false });
    expect(report.liveRequested).toBe(false);
    expect(report.lanes.filter((lane) => lane.mode === "fixture")).toHaveLength(3);
    for (const lane of report.lanes.filter((candidate) => candidate.mode === "fixture")) {
      expect(lane.status).toBe("passed");
      expect(lane.adapterRegistered).toBe(true);
      expect(lane.leaseReceipts.map((receipt) => receipt.operation)).toEqual(["acquire", "acquire", "acquire", "release"]);
      expect(lane.leaseReceipts[1]?.replayed).toBe(true);
      expect(lane.workspace.lifecycle).toBe("stopped");
      expect(lane.workspace.replayed).toBe(true);
      expect(lane.promotion.runtimeId).toMatch(/^runtime_/);
      expect(lane.promotion.workspaceId).toMatch(/^workspace_/);
      expect(lane.effectReceipts.some((receipt) => receipt.replayed)).toBe(true);
    }
  });

  test("reports live lanes as skipped without complete explicit config", async () => {
    const report = await runCrossHostVerification({ env: { CMUX_CROSS_HOST_LIVE: "1" }, live: true });
    const live = report.lanes.filter((lane) => lane.mode === "live");
    expect(live.map((lane) => lane.provider)).toEqual(["huge-blue", "freestyle"]);
    expect(live.every((lane) => lane.status === "skipped")).toBe(true);
    expect(JSON.stringify(report)).not.toContain("token");
    expect(report.liveConfig["huge-blue"].configured).toBe(false);
    expect(report.liveConfig.freestyle.configured).toBe(false);
  });

  test("does not expose provider credentials in fixture receipts", async () => {
    const report = await runCrossHostVerification({ env: {}, live: false });
    const serialized = JSON.stringify(report);
    expect(serialized).not.toContain("fixture-token");
    expect(serialized).not.toContain("authorization");
    expect(serialized).not.toContain("secret");
  });
});
