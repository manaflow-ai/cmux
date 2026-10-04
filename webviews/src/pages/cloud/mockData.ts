// Sample data for the mock provider (dev loop and tests). Shapes follow the Cloud app server's
// recorded fixtures (first-party-apps/cloud/server/tests/fixtures/, from `web/app/api/vm/**`).
// Names, ids and addresses are made up.
import type {
  CloudDomain,
  CloudMachine,
  CloudNetwork,
  CloudPlan,
  CloudPublication,
  CloudSnapshot,
  CloudTeam,
  CloudUsage,
  FirewallRule,
  MachineStats,
} from "./ops";

const DAY = 86_400_000;
const T0 = Date.UTC(2026, 9, 1, 9, 30);

const creator = { userId: "user-dev-1", displayName: "Dev User" };

export function sampleMachines(): CloudMachine[] {
  return [
    {
      id: "vm-a1",
      provider: "freestyle",
      status: "running",
      displayName: "api-dev",
      slug: "api-dev",
      kind: "terminal",
      image: "cmux-base",
      imageVersion: "20260902e",
      createdAt: T0 - 3 * DAY,
      address: { ipv4: "10.42.0.11", ipv6: null },
      createdBy: creator,
      freeAccessExpiresAt: null,
    },
    {
      id: "vm-b2",
      provider: "freestyle",
      status: "paused",
      displayName: "build-cache",
      slug: "build-cache",
      kind: "terminal",
      image: "cmux-base",
      imageVersion: "20260902e",
      createdAt: T0 - 10 * DAY,
      address: { ipv4: null, ipv6: null },
      createdBy: creator,
      freeAccessExpiresAt: null,
    },
    {
      id: "vm-c3",
      provider: "freestyle",
      status: "provisioning",
      displayName: null,
      slug: "quiet-otter",
      kind: "terminal",
      image: "cmux-base",
      imageVersion: "20260902e",
      createdAt: T0,
      address: null,
      createdBy: null,
      freeAccessExpiresAt: null,
    },
  ];
}

/** Snapshots by machine. `createdAt` is an ISO string, as the snapshots route answers it. */
export function sampleSnapshots(): Array<CloudSnapshot & { machine: string }> {
  return [
    { id: "snap-1", name: "before upgrade", machine: "vm-a1", createdAt: new Date(T0 - DAY).toISOString() },
    { id: "snap-2", name: null, machine: "vm-a1", createdAt: new Date(T0 - 2 * DAY).toISOString() },
    { id: "snap-3", name: "warm cache", machine: "vm-b2", createdAt: new Date(T0 - 5 * DAY).toISOString() },
  ];
}

/** `GET /api/vm/:id/stats`: sleeping machines answer `asleep` with no numbers. */
export function sampleStats(machine: CloudMachine, memoryMb = 8192): MachineStats {
  if (machine.status !== "running") return { state: "asleep" };
  return {
    state: "awake",
    cpus: 4,
    cpuPercent: 12.5,
    loadAverage1m: 0.4,
    memoryTotalMb: memoryMb,
    memoryUsedMb: 2048,
    diskTotalMb: 65_536,
    diskUsedMb: 10_240,
  };
}

export interface SampleAccount {
  team: string;
  teams: CloudTeam[];
  plan: CloudPlan;
  usage: CloudUsage;
  domains: CloudDomain[];
  publications: CloudPublication[];
  networks: CloudNetwork[];
  firewall: FirewallRule[];
}

export function sampleAccount(): SampleAccount {
  return {
    team: "team-personal",
    teams: [
      { id: "team-personal", name: "Personal" },
      { id: "team-acme", name: "Acme" },
    ],
    // The `limits` of `GET /api/vm`, as `cloud.plan.get` answers them.
    plan: {
      planId: "go",
      maxActiveVms: 3,
      activeVmCount: 2,
      memoryOptionsMb: [4096, 8192],
      lockedMemoryOptionsMb: [16_384, 32_768],
      memoryUpgradePlanId: "pro",
      freeAccessExpiresAt: null,
      freeAccessWindowDays: 0,
    },
    usage: { vmHoursUsed: 12.5, vmHoursIncluded: 40, activeVmCount: 2, savedVmLimit: 5 },
    domains: [
      { name: "dev.example.com", status: "verified" },
      { name: "preview.example.org", status: "pending" },
    ],
    publications: [
      { id: "pub-1", machine: "vm-a1", hostname: "3000-api-dev.example.dev", port: 3000, status: "active" },
    ],
    networks: [{ id: "vpc-1", cidr: "10.42.0.0/16", scope: "team" }],
    firewall: [
      {
        id: "fw-1",
        action: "allow",
        source: { public: true },
        destination: { vmId: "vm-a1", port: 443, protocol: "tcp" },
        description: "HTTPS",
      },
      {
        id: "fw-2",
        action: "allow",
        source: { cidr: "10.42.0.0/16" },
        destination: { vmId: "vm-a1", port: 5432, protocol: "tcp" },
      },
    ],
  };
}
