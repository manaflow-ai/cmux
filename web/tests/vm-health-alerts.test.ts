import { describe, expect, test } from "bun:test";

import type { AlertInput } from "../services/observability/alerts";
import type { VmAlertStateStore } from "../services/observability/vmAlerts";
import { deliverVmHealthAlert, VM_HEALTH_ALERT_KEY, vmHealthAlert } from "../services/observability/vmHealthAlerts";
import type { VmHealthReport } from "../services/vms/health/types";

function report(overrides: Partial<VmHealthReport> = {}): VmHealthReport {
  return {
    version: 1,
    generatedAt: "2026-10-12T12:00:00.000Z",
    durationMs: 1,
    stateCounts: {},
    workloadCounts: {},
    coverage: { inventoryComplete: true, running: 0, probed: 0, probeErrors: 0, skippedBudget: 0, skippedIdle: 0 },
    hung: [],
    stuck: [],
    transitions: [],
    drift: [],
    tls: null,
    errors: [],
    attention: { needed: false, reasons: [] },
    ...overrides,
  };
}

const hungReport = report({
  hung: [{
    vmId: "vm-1", workload: "app:chatmux2", owner: null, snapshot: null,
    size: { cpu: null, memoryMib: null, storageMib: null },
    firstSeenHungAt: "2026-10-12T11:00:00.000Z", providerUpdatedAt: "2026-10-12T10:00:00.000Z", dbUpdatedAt: null, detail: "timeout",
  }],
});

/** The durable store's contract: a claim succeeds when inactive, escalated, or 24 hours after the last page. */
function memoryStore() {
  const state = { active: false, severity: "warning", lastSentAt: null as Date | null, clears: 0 };
  const store: VmAlertStateStore = {
    claim: async (input: AlertInput, now: Date) => {
      const escalated = input.severity === "critical" && state.severity !== "critical";
      const reminder = !state.lastSentAt || now.getTime() - state.lastSentAt.getTime() >= 24 * 3600_000;
      if (state.active && !escalated && !reminder) return null;
      state.active = true;
      state.severity = input.severity;
      return "lease";
    },
    acknowledge: async (_key, _lease, now) => {
      state.lastSentAt = now;
    },
    clear: async () => {
      state.active = false;
      state.clears += 1;
    },
  };
  return { state, store };
}

describe("vm health alert", () => {
  test("hung VMs are critical and name the workloads; a clean report has no alert", () => {
    const alert = vmHealthAlert(hungReport, "https://cmux.com/dashboard/ops/cloud-vms")!;
    expect(alert.key).toBe(VM_HEALTH_ALERT_KEY);
    expect(alert.severity).toBe("critical");
    expect(alert.body).toContain("1 app:chatmux2");
    expect(alert.body).toContain("https://cmux.com/dashboard/ops/cloud-vms");
    expect(vmHealthAlert(report(), null)).toBeNull();
  });

  test("pages once per incident and at most once an hour when a VM flaps", async () => {
    const { state, store } = memoryStore();
    const sent: AlertInput[] = [];
    const send = async (input: AlertInput) => {
      sent.push(input);
      return { sent: true, configured: true };
    };
    const lastSentAt = async () => state.lastSentAt;
    const at = (minutes: number) => new Date(Date.UTC(2026, 9, 12, 12, minutes));

    expect(await deliverVmHealthAlert(hungReport, { now: at(0), store, send, lastSentAt })).toBe("sent");
    expect(await deliverVmHealthAlert(hungReport, { now: at(5), store, send, lastSentAt })).toBe("suppressed");
    // Clean, then hung again inside the hour: the state was not cleared, so no new page.
    expect(await deliverVmHealthAlert(report(), { now: at(10), store, send, lastSentAt })).toBe("none");
    expect(state.clears).toBe(0);
    expect(await deliverVmHealthAlert(hungReport, { now: at(15), store, send, lastSentAt })).toBe("suppressed");
    expect(sent).toHaveLength(1);
    // A clean sweep an hour after the page clears it, and the next incident pages.
    expect(await deliverVmHealthAlert(report(), { now: at(61), store, send, lastSentAt })).toBe("none");
    expect(state.clears).toBe(1);
    expect(await deliverVmHealthAlert(hungReport, { now: at(66), store, send, lastSentAt })).toBe("sent");
    expect(sent).toHaveLength(2);
  });

  test("a blind sweep never clears a live alert", async () => {
    const { state, store } = memoryStore();
    const send = async () => ({ sent: true, configured: true });
    const lastSentAt = async () => state.lastSentAt;
    const at = (minutes: number) => new Date(Date.UTC(2026, 9, 12, 12, minutes));
    await deliverVmHealthAlert(hungReport, { now: at(0), store, send, lastSentAt });
    const blind = [
      report({ errors: [{ stage: "inventory", message: "503" }], coverage: { ...report().coverage, inventoryComplete: false } }),
      report({ coverage: { ...report().coverage, skippedBudget: 30 } }),
    ];
    for (const sweep of blind) {
      expect(await deliverVmHealthAlert(sweep, { now: at(120), store, send, lastSentAt })).toBe("none");
    }
    expect(state.clears).toBe(0);
    expect(await deliverVmHealthAlert(report(), { now: at(125), store, send, lastSentAt })).toBe("none");
    expect(state.clears).toBe(1);
  });

  test("a failed delivery releases its lease so the next sweep retries", async () => {
    const released: string[] = [];
    const claims: string[] = [];
    const store: VmAlertStateStore = {
      claim: async () => {
        claims.push("claim");
        return released.length >= claims.length - 1 ? `lease-${claims.length}` : null;
      },
      acknowledge: async () => undefined,
      clear: async () => undefined,
      release: async (key, leaseId) => {
        released.push(`${key}:${leaseId}`);
      },
    };
    const failing = async () => ({ sent: false, configured: true, status: 500 });
    expect(await deliverVmHealthAlert(hungReport, { store, send: failing, lastSentAt: async () => null })).toBe("failed");
    expect(released).toEqual([`${VM_HEALTH_ALERT_KEY}:lease-1`]);
    expect(await deliverVmHealthAlert(hungReport, { store, send: failing, lastSentAt: async () => null })).toBe("failed");
  });

  test("a failing alert path never fails the sweep", async () => {
    const { store } = memoryStore();
    const outcome = await deliverVmHealthAlert(hungReport, {
      store,
      send: async () => {
        throw new Error("slack down");
      },
      lastSentAt: async () => null,
    });
    expect(outcome).toBe("failed");
  });
});
