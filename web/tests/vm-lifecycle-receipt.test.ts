import { describe, expect, test } from "bun:test";
import {
  buildLifecycleReceipt,
  finalLifecycleState,
  LIFECYCLE_RECEIPT_SCHEMA,
  LIFECYCLE_STATES,
} from "../scripts/cloud-vm/lifecycle-receipt.mjs";

describe("Cloud lifecycle receipt", () => {
  test("keeps every required lifecycle slice explicit", () => {
    const receipt = buildLifecycleReceipt({
      ok: true,
      sourceSha: "0123456789abcdef0123456789abcdef01234567",
      provider: "freestyle",
      imageVersion: "devbox-20261023",
      machineId: "vm_0123456789abcdef0123",
      attachState: "completed",
      networkState: "completed",
      transportPath: "wireguard",
      terminalState: "completed",
      operations: [{ name: "create", states: [{ state: "accepted", atMs: 0 }, { state: "running", atMs: 1 }, { state: "completed", atMs: 20 }] }],
    });

    expect(receipt.schema).toBe(LIFECYCLE_RECEIPT_SCHEMA);
    expect(receipt.state).toBe("completed");
    expect(receipt.source).toMatchObject({ state: "completed" });
    expect(receipt.provider).toMatchObject({ state: "completed", name: "freestyle" });
    expect(receipt.attach.state).toBe("completed");
    expect(receipt.network).toMatchObject({ state: "completed", transportPath: "wireguard" });
    expect(receipt.forkSnapshot).toMatchObject({ state: "unverified" });
    expect(receipt.quota).toMatchObject({ state: "unverified" });
    expect(receipt.operations[0]?.states.map((entry: { state: string }) => entry.state)).toEqual(["accepted", "running", "completed"]);
  });

  test("never upgrades missing evidence and preserves cancellation", () => {
    const receipt = buildLifecycleReceipt({
      ok: false,
      cancelled: true,
      operations: [{ name: "attach", states: [{ state: "accepted" }, { state: "running" }, { state: "failed" }] }],
    });
    expect(receipt.state).toBe("cancelled");
    expect(receipt.source).toMatchObject({ state: "unverified" });
    expect(receipt.lease).toMatchObject({ state: "unverified" });
    expect(receipt.cleanup).toMatchObject({ state: "unverified" });
    expect(receipt.operations[0]?.states.at(-1)).toMatchObject({ state: "failed" });
    expect(finalLifecycleState({})).toBe("unverified");
  });

  test("recognizes only the six published states", () => {
    expect(LIFECYCLE_STATES).toEqual(["accepted", "running", "completed", "failed", "cancelled", "unverified"]);
    expect(buildLifecycleReceipt({ state: "invented" }).state).toBe("unverified");
  });
});
