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

/** A small guest tree per machine (fixtures fs-dir.json, fs-stat.json, fs-read.json, fs-stat-large.json). */
export interface SampleFile {
  kind: "file" | "directory" | "symlink";
  /** File content; a file without one is large (`size` only). */
  text?: string;
  size?: number;
  mode?: number;
  modifiedAt?: number;
}

export function sampleFiles(): Map<string, SampleFile> {
  return new Map<string, SampleFile>([
    ["/home/cmux", { kind: "directory" }],
    ["/home/cmux/notes.txt", { kind: "file", text: "hello cloud\n", mode: 420, modifiedAt: 1_791_100_000_000 }],
    ["/home/cmux/src", { kind: "directory" }],
    ["/home/cmux/src/main.rs", { kind: "file", text: "fn main() {}\n", mode: 420 }],
    ["/home/cmux/big.bin", { kind: "file", size: 20_971_520 }],
    // fs-dir.json lists a symlink with no size.
    ["/home/cmux/latest", { kind: "symlink" }],
  ]);
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
    // The server's answers (first-party-apps/cloud/server/tests/fixtures/{domain,publication,network,
    // firewall}-list.json), with the sample machine ids.
    domains: [
      {
        id: "dom-test01",
        hostname: "example.test",
        verificationState: "pending",
        certificateState: "pending",
        createdAt: "2026-10-01T00:00:00.000Z",
        dnsInstructions: [
          { purpose: "verification", recordTypes: ["TXT"], name: "_cmux.example.test", value: "cmux-verify=test" },
        ],
        publications: [{ id: "00000000-0000-4000-8000-000000000001", hostname: "app.example.test", state: "pending" }],
      },
    ],
    publications: [
      {
        id: "00000000-0000-4000-8000-000000000001",
        hostname: "app.example.test",
        url: "https://app.example.test",
        domainKind: "custom",
        vmId: "vm-a1",
        port: 3000,
        accessMode: "personal",
        teamId: null,
        state: "pending",
        routingRevision: 1,
        verification: null,
      },
      {
        id: "00000000-0000-4000-8000-000000000002",
        hostname: "quiet-test-label.cmux.sh",
        url: "https://quiet-test-label.cmux.sh",
        domainKind: "generated",
        vmId: "vm-b2",
        port: 8080,
        accessMode: "team",
        teamId: "team-personal",
        state: "active",
        routingRevision: 3,
        verification: null,
      },
    ],
    networks: [{ id: "vpc-test01", cidr: "10.64.0.0/16", cidrV6: "fd00:64::/48", scope: "user" }],
    firewall: [
      {
        id: "fw-test01",
        action: "allow",
        source: { public: true },
        destination: { vmId: "vm-a1", port: 443, protocol: "tcp" },
        description: "https",
        createdAt: "2026-10-01T00:00:00.000Z",
      },
      {
        id: "fw-test03",
        action: "allow",
        source: { cidr: "10.64.0.0/16" },
        destination: { vmId: "vm-a1", port: 5432, protocol: "tcp" },
      },
    ],
  };
}
