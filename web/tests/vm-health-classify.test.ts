import { describe, expect, test } from "bun:test";

import { classifyVmHealth, tlsRuleOwner, vmWorkload } from "../services/vms/health/classify";
import { tlsRuleRef } from "../services/vms/drivers/freestyleHealthInventory";
import { sanitizeDetail } from "../services/vms/health/sanitize";
import type { ProviderInventoryVm, ProviderTlsRuleRef, VmHealthDbRow, VmProbeRecord } from "../services/vms/health/types";

const NOW = new Date("2026-10-12T12:00:00.000Z");
const minutesAgo = (minutes: number) => new Date(NOW.getTime() - minutes * 60_000).toISOString();
const daysAgo = (days: number) => minutesAgo(days * 24 * 60);

function vm(id: string, overrides: Partial<ProviderInventoryVm> = {}): ProviderInventoryVm {
  return {
    id,
    state: "running",
    metadata: { cmux: "cloud" },
    snapshot: "cmux-devbox-4x8",
    cpu: 4,
    memoryMib: 8192,
    storageMib: 20480,
    idleTimeoutSeconds: -1,
    vpcIds: [],
    createdAt: daysAgo(3),
    updatedAt: daysAgo(1),
    ...overrides,
  };
}

function row(providerVmId: string, overrides: Partial<VmHealthDbRow> = {}): VmHealthDbRow {
  return {
    id: `row-${providerVmId}`,
    providerVmId,
    userId: `user-${providerVmId}`,
    ownerTeamId: `team-${providerVmId}`,
    status: "running",
    imageId: "devbox",
    createdAt: new Date(daysAgo(3)),
    updatedAt: new Date(daysAgo(1)),
    ...overrides,
  };
}

function classify(input: Partial<Parameters<typeof classifyVmHealth>[0]> & { vms?: ProviderInventoryVm[] }) {
  const { vms, ...rest } = input;
  return classifyVmHealth({
    now: NOW,
    startedAt: new Date(NOW.getTime() - 30_000),
    inventory: { vms: vms ?? [], complete: true },
    tlsRules: null,
    dbRows: [],
    probes: [],
    previousHung: [],
    errors: [],
    ...rest,
  });
}

describe("workload", () => {
  test("cmux Cloud, other apps on the shared account, and everything else", () => {
    expect(vmWorkload({ cmux: "cloud" })).toBe("cmux_cloud");
    expect(vmWorkload({ app: "chatmux2" })).toBe("app:chatmux2");
    expect(vmWorkload({})).toBe("other");
  });
});

describe("hung VMs", () => {
  test("a running VM whose probe timed out or hit a stale runtime is hung, with owner, image and size", () => {
    const report = classify({
      vms: [vm("vm-a"), vm("vm-b", { metadata: { app: "chatmux2" } }), vm("vm-ok")],
      dbRows: [row("vm-a")],
      probes: [
        { vmId: "vm-a", outcome: "hung", latencyMs: 10_000, detail: "timeout after 10000ms" },
        { vmId: "vm-b", outcome: "hung", latencyMs: 40, detail: "409 conflict: vm runtime stale runtime instance responsive=false" },
        { vmId: "vm-ok", outcome: "ok", latencyMs: 30 },
      ],
    });
    expect(report.hung.map((entry) => entry.vmId).sort()).toEqual(["vm-a", "vm-b"]);
    const a = report.hung.find((entry) => entry.vmId === "vm-a")!;
    expect(a.workload).toBe("cmux_cloud");
    expect(a.owner).toEqual({ cloudVmId: "row-vm-a", userId: "user-vm-a", teamId: "team-vm-a" });
    expect(a.snapshot).toBe("cmux-devbox-4x8");
    expect(a.size).toEqual({ cpu: 4, memoryMib: 8192, storageMib: 20480 });
    expect(a.firstSeenHungAt).toBe(NOW.toISOString());
    expect(a.dbUpdatedAt).toBe(daysAgo(1));
    const b = report.hung.find((entry) => entry.vmId === "vm-b")!;
    expect(b.workload).toBe("app:chatmux2");
    expect(b.owner).toBeNull();
    expect(report.attention.needed).toBe(true);
    expect(report.attention.reasons).toContainEqual({ code: "hung_vms", count: 2 });
  });

  test("first-seen-hung time carries over from the previous sweep", () => {
    const report = classify({
      vms: [vm("vm-a")],
      probes: [{ vmId: "vm-a", outcome: "hung", latencyMs: 10_000, detail: "timeout" }],
      previousHung: [{ vmId: "vm-a", firstSeenHungAt: minutesAgo(45) }, { vmId: "vm-recovered", firstSeenHungAt: minutesAgo(90) }],
    });
    expect(report.hung).toHaveLength(1);
    expect(report.hung[0]!.firstSeenHungAt).toBe(minutesAgo(45));
  });

  test("probe errors and gone VMs are not hung; a few errors are noise, many make the sweep incomplete", () => {
    const report = classify({
      vms: [vm("vm-a"), vm("vm-b")],
      probes: [
        { vmId: "vm-a", outcome: "error", latencyMs: 3, detail: "429 rate limited" },
        { vmId: "vm-b", outcome: "gone", latencyMs: 3 },
      ],
    });
    expect(report.hung).toEqual([]);
    expect(report.coverage.probeErrors).toBe(1);
    expect(report.attention).toEqual({ needed: false, reasons: [] });

    const vms = Array.from({ length: 20 }, (_, index) => vm(`vm-${index}`));
    const many = classify({ vms, probes: vms.slice(0, 5).map((entry) => ({ vmId: entry.id, outcome: "error", latencyMs: 3, detail: "state read: 503" })) });
    expect(many.attention.reasons).toContainEqual({ code: "sweep_incomplete", unprobed: 5 });
  });

  test("a VM paused after the listing is not probed, not hung, and not counted as probed", () => {
    const report = classify({
      vms: [vm("vm-a")],
      probes: [{ vmId: "vm-a", outcome: "not_running", latencyMs: 20 }],
      previousHung: [{ vmId: "vm-a", firstSeenHungAt: minutesAgo(30) }],
    });
    expect(report.hung).toEqual([]);
    expect(report.coverage).toMatchObject({ probed: 0, skippedNotRunning: 1 });
  });

  test("a hung VM this sweep could not re-probe stays hung with its first-seen time", () => {
    const report = classify({
      vms: [vm("vm-a"), vm("vm-b"), vm("vm-c")],
      probes: [
        { vmId: "vm-a", outcome: "skipped_budget" },
        { vmId: "vm-b", outcome: "error", latencyMs: 1, detail: "429" },
        { vmId: "vm-c", outcome: "ok", latencyMs: 1 },
      ],
      previousHung: ["vm-a", "vm-b", "vm-c"].map((vmId) => ({ vmId, firstSeenHungAt: minutesAgo(30) })),
    });
    expect(report.hung.map((entry) => `${entry.vmId}:${entry.firstSeenHungAt === minutesAgo(30)}`)).toEqual(["vm-a:true", "vm-b:true"]);
    expect(report.hung[0]!.detail).toContain("not re-probed");
  });

  test("a healthy fleet needs no attention", () => {
    const report = classify({
      vms: [vm("vm-a"), vm("vm-p", { state: "paused" })],
      dbRows: [row("vm-a"), row("vm-p", { status: "paused" })],
      probes: [{ vmId: "vm-a", outcome: "ok", latencyMs: 20 }],
      tlsRules: { totalCount: 10, rules: [], complete: true },
    });
    expect(report.attention).toEqual({ needed: false, reasons: [] });
    expect(report.stateCounts).toEqual({ running: 1, paused: 1 });
  });
});

describe("stuck transitions", () => {
  test("transitions seen past the threshold and old DB provisioning rows are stuck", () => {
    const report = classify({
      vms: [
        vm("vm-pausing", { state: "pausing" }),
        vm("vm-starting-fresh", { state: "starting" }),
        vm("vm-starting", { state: "starting" }),
      ],
      previousTransitions: [
        { vmId: "vm-pausing", state: "pausing", firstSeenAt: minutesAgo(40) },
        { vmId: "vm-starting-fresh", state: "starting", firstSeenAt: minutesAgo(2) },
        { vmId: "vm-starting", state: "starting", firstSeenAt: minutesAgo(16) },
      ],
      dbRows: [
        row("vm-prov", { status: "provisioning", updatedAt: new Date(minutesAgo(30)) }),
        row("vm-prov-new", { status: "provisioning", updatedAt: new Date(minutesAgo(1)) }),
      ],
    });
    expect(report.stuck.map((entry) => `${entry.source}:${entry.vmId}:${entry.minutes}`)).toEqual([
      "provider:vm-pausing:40",
      "db:vm-prov:30",
      "provider:vm-starting:16",
    ]);
    expect(report.attention.reasons).toContainEqual({ code: "stuck_transitions", count: 3 });
    expect(report.transitions.map((entry) => entry.vmId).sort()).toEqual(["vm-pausing", "vm-starting", "vm-starting-fresh"]);
  });

  test("a transition is dated by sightings, never by the provider timestamp", () => {
    // A paused VM that starts may keep its days-old pause time as updatedAt;
    // that must not make a fresh transition look stuck on its first sighting.
    const vms = [vm("vm-starting", { state: "starting", updatedAt: daysAgo(9) })];
    const first = classify({ vms });
    expect(first.stuck).toEqual([]);
    expect(first.transitions).toEqual([{ vmId: "vm-starting", state: "starting", firstSeenAt: NOW.toISOString() }]);
    const later = classify({ vms, previousTransitions: [{ vmId: "vm-starting", state: "starting", firstSeenAt: minutesAgo(20) }] });
    expect(later.stuck.map((entry) => `${entry.vmId}:${entry.minutes}`)).toEqual(["vm-starting:20"]);
    // A different transition of the same VM starts a new clock.
    const restarted = classify({ vms, previousTransitions: [{ vmId: "vm-starting", state: "pausing", firstSeenAt: minutesAgo(20) }] });
    expect(restarted.stuck).toEqual([]);
  });

  test("the threshold is configurable", () => {
    const report = classify({
      vms: [vm("vm-pausing", { state: "pausing" })],
      previousTransitions: [{ vmId: "vm-pausing", state: "pausing", firstSeenAt: minutesAgo(6) }],
      thresholds: { stuckAfterMs: 5 * 60_000 },
    });
    expect(report.stuck).toHaveLength(1);
  });
});

describe("drift", () => {
  test("DB running but missing at the provider is drift only when the inventory is complete", () => {
    const dbRows = [row("vm-gone")];
    expect(classify({ dbRows }).drift.map((entry) => entry.kind)).toEqual(["provider_missing"]);
    const partial = classifyVmHealth({
      now: NOW, startedAt: NOW, inventory: { vms: [], complete: false }, tlsRules: null,
      dbRows, probes: [], previousHung: [], errors: [],
    });
    expect(partial.drift).toEqual([]);
    expect(partial.attention.reasons).toContainEqual({ code: "sweep_incomplete", unprobed: 0 });
  });

  test("state mismatches in both directions", () => {
    const report = classify({
      vms: [vm("vm-1", { state: "paused" }), vm("vm-2", { state: "running" }), vm("vm-3", { state: "stopped" })],
      dbRows: [row("vm-1"), row("vm-2", { status: "paused" }), row("vm-3")],
    });
    expect(report.drift.map((entry) => `${entry.vmId}:${entry.kind}`)).toEqual([
      "vm-2:db_paused_provider_running",
      "vm-1:db_running_provider_paused",
      "vm-3:db_running_provider_paused",
    ]);
  });

  test("cmux VMs the DB does not track, or tracks as destroyed, are drift; other workloads are not", () => {
    const report = classify({
      vms: [
        vm("vm-untracked"),
        vm("vm-destroyed"),
        vm("vm-chat", { metadata: { app: "chatmux2" } }),
        vm("vm-stopped-untracked", { state: "stopped" }),
      ],
      dbRows: [row("vm-destroyed", { status: "destroyed", updatedAt: new Date(daysAgo(2)) })],
    });
    expect(report.drift.map((entry) => `${entry.vmId}:${entry.kind}`)).toEqual([
      "vm-destroyed:db_destroyed_provider_present",
      "vm-untracked:provider_untracked",
    ]);
  });

  test("untracked cmux VMs are listed but do not by themselves need attention", () => {
    // Another environment on the shared account tags its VMs cmux=cloud too.
    const report = classify({ vms: [vm("vm-staging")] });
    expect(report.drift.map((entry) => entry.kind)).toEqual(["provider_untracked"]);
    expect(report.attention).toEqual({ needed: false, reasons: [] });
  });

  test("recent changes are in-flight lifecycle calls, not drift", () => {
    const report = classify({
      vms: [vm("vm-new", { createdAt: minutesAgo(2), updatedAt: minutesAgo(2) }), vm("vm-pausing-now", { state: "paused", updatedAt: minutesAgo(1) })],
      dbRows: [row("vm-pausing-now"), row("vm-just-created", { updatedAt: new Date(minutesAgo(1)) })],
    });
    expect(report.drift).toEqual([]);
  });

  test("a running VM's activity-driven updatedAt does not hide drift", () => {
    const report = classify({
      vms: [vm("vm-untracked", { updatedAt: minutesAgo(1) }), vm("vm-resumed", { updatedAt: minutesAgo(1) })],
      dbRows: [row("vm-resumed", { status: "paused" })],
    });
    expect(report.drift.map((entry) => `${entry.vmId}:${entry.kind}`)).toEqual([
      "vm-resumed:db_paused_provider_running",
      "vm-untracked:provider_untracked",
    ]);
  });
});

describe("TLS rule budget", () => {
  const vms = [
    vm("vm-cmux", { vpcIds: ["vpc-cmux"] }),
    vm("vm-chat", { metadata: { app: "chatmux2" } }),
    vm("vm-paused-old", { state: "paused", updatedAt: daysAgo(10) }),
    vm("vm-paused-new", { state: "paused", updatedAt: daysAgo(2) }),
  ];
  const rule = (id: string, overrides: Partial<ProviderTlsRuleRef> = {}): ProviderTlsRuleRef => ({ id, managed: false, vmIds: [], vpcIds: [], ...overrides });

  test("over the 200,000 limit, attributed by owner, with idle paused holders", () => {
    const rules = [
      rule("r1", { vmIds: ["vm-cmux"] }),
      rule("r2", { vmIds: ["vm-cmux"] }),
      rule("r3", { vmIds: ["vm-chat"] }),
      rule("r4"),
      rule("r5", { vpcIds: ["vpc-cmux"] }),
      rule("r6", { vpcIds: ["vpc-unknown"] }),
      rule("r7", { vmIds: ["vm-deleted"] }),
      rule("r8", { vmIds: ["vm-paused-old"] }),
      rule("r9", { vmIds: ["vm-paused-old"] }),
      rule("r10", { vmIds: ["vm-paused-new"] }),
      rule("r11", { managed: true }),
    ];
    const report = classify({ vms, tlsRules: { totalCount: 200_303, rules, complete: false } });
    const tls = report.tls!;
    expect(tls.totalCount).toBe(200_303);
    expect(tls.limit).toBe(200_000);
    expect(tls.complete).toBe(false);
    expect(tls.byOwner).toEqual({
      cmux_cloud: 6,
      "app:chatmux2": 1,
      account_level: 1,
      vpc_unattributed: 1,
      unknown_vm: 1,
      managed: 1,
    });
    expect(tls.pausedHolders.vmCount).toBe(1);
    expect(tls.pausedHolders.ruleCount).toBe(2);
    expect(tls.pausedHolders.top[0]).toMatchObject({ vmId: "vm-paused-old", rules: 2, workload: "cmux_cloud" });
    expect(report.attention.needed).toBe(true);
    expect(report.attention.reasons).toContainEqual({ code: "tls_over_limit", count: 200_303, limit: 200_000 });
  });

  test("near the limit is a warning that does not by itself need attention", () => {
    const report = classify({ vms: [], tlsRules: { totalCount: 180_000, rules: [], complete: true } });
    expect(report.attention.reasons).toEqual([{ code: "tls_near_limit", count: 180_000, limit: 200_000 }]);
    expect(report.attention.needed).toBe(false);
  });

  test("rule owner falls back from VM to network to account", () => {
    const byId = new Map(vms.map((entry) => [entry.id, entry]));
    const vpc = new Map([["vpc-cmux", "cmux_cloud"]]);
    expect(tlsRuleOwner(rule("x", { vmIds: ["vm-chat"], vpcIds: ["vpc-cmux"] }), byId, vpc)).toBe("app:chatmux2");
    expect(tlsRuleOwner(rule("x", { vpcIds: ["vpc-cmux"] }), byId, vpc)).toBe("cmux_cloud");
    expect(tlsRuleOwner(rule("x"), byId, vpc)).toBe("account_level");
  });

  test("the provider rule reduces to ids; domains and transforms are dropped", () => {
    const ref = tlsRuleRef({
      id: "rule-1",
      accountId: "acct",
      action: "allow",
      domain: "api.openai.com",
      protocol: "http",
      source: { vmId: "vm-src" },
      destination: { public: true },
      transform: [{ headers: { authorization: "***" } }],
      dependencies: [{ kind: "vm", id: "vm-src" }, { kind: "vpc", id: "vpc-1" }],
      createdAt: daysAgo(1),
      updatedAt: daysAgo(1),
    } as unknown as Parameters<typeof tlsRuleRef>[0]);
    expect(ref).toEqual({ id: "rule-1", managed: false, vmIds: ["vm-src"], vpcIds: ["vpc-1"] });
    expect(JSON.stringify(ref)).not.toContain("openai");
  });
});

describe("probe detail", () => {
  test("token-shaped text is redacted and the detail is bounded", () => {
    const detail = sanitizeDetail(`409 conflict bearer abc123 ${"x".repeat(40)} ${"y ".repeat(300)}`);
    expect(detail).not.toContain("abc123");
    expect(detail).not.toContain("x".repeat(40));
    expect(detail.length).toBeLessThanOrEqual(200);
  });
});

describe("report bounds", () => {
  test("lists are capped so one incident cannot make a snapshot unbounded", () => {
    const vms = Array.from({ length: 700 }, (_, index) => vm(`vm-${index}`));
    const probes: VmProbeRecord[] = vms.map((entry) => ({ vmId: entry.id, outcome: "hung", latencyMs: 10_000, detail: "timeout" }));
    const report = classify({ vms, probes });
    expect(report.hung).toHaveLength(500);
    // The reason keeps the true count while the stored list is capped.
    expect(report.attention.reasons).toContainEqual({ code: "hung_vms", count: 700 });
  });
});
