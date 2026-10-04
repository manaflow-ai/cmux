// Sample data for the mock provider (dev loop and tests). Names and hosts are made up.
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

export function sampleMachines(): CloudMachine[] {
  return [
    {
      id: "vm-a1",
      provider: "freestyle",
      status: "running",
      display_name: "api-dev",
      slug: "api-dev",
      image: "cmux-base",
      image_version: "20260902e",
      created_at_ms: T0 - 3 * DAY,
      address: { ipv4: "10.42.0.11" },
      size: { name: "standard-2", cpu: 2, memory_mb: 4096, storage_mb: 20_480 },
      idle_timeout_seconds: 3600,
    },
    {
      id: "vm-b2",
      provider: "freestyle",
      status: "paused",
      display_name: "build-cache",
      image: "cmux-base",
      created_at_ms: T0 - 10 * DAY,
      address: { ipv4: "10.42.0.12" },
      size: { name: "performance-4", cpu: 4, memory_mb: 8192, storage_mb: 51_200 },
    },
    {
      id: "vm-c3",
      provider: "freestyle",
      status: "provisioning",
      display_name: "scratch",
      image: "cmux-base",
      created_at_ms: T0,
      size: { name: "small-1", cpu: 1, memory_mb: 2048, storage_mb: 10_240 },
      idle_timeout_seconds: 300,
    },
  ];
}

export function sampleSnapshots(): CloudSnapshot[] {
  return [
    { id: "snap-1", name: "before upgrade", machine: "vm-a1", created_at_ms: T0 - DAY },
    { id: "snap-2", machine: "vm-a1", created_at_ms: T0 - 2 * DAY },
    { id: "snap-3", name: "warm cache", machine: "vm-b2", created_at_ms: T0 - 5 * DAY },
  ];
}

export function sampleStats(machine: CloudMachine): MachineStats {
  if (machine.status !== "running") return { state: machine.status };
  return {
    state: "running",
    cpus: machine.size?.cpu,
    cpu_percent: 23,
    memory_total_mb: machine.size?.memory_mb,
    memory_used_mb: 1536,
    disk_total_mb: machine.size?.storage_mb,
    disk_used_mb: 7168,
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
    plan: {
      name: "Pro",
      machine_limit: 5,
      upgradable: true,
      sizes: [
        { name: "small-1", cpu: 1, memory_mb: 2048, storage_mb: 10_240, allowed: true },
        { name: "standard-2", cpu: 2, memory_mb: 4096, storage_mb: 20_480, allowed: true },
        { name: "performance-4", cpu: 4, memory_mb: 8192, storage_mb: 51_200, allowed: true },
        { name: "large-8", cpu: 8, memory_mb: 16_384, storage_mb: 102_400, allowed: false },
      ],
    },
    usage: {
      period_start_ms: Date.UTC(2026, 9, 1),
      period_end_ms: Date.UTC(2026, 10, 1),
      compute_hours: 42.5,
      compute_hours_limit: 300,
      storage_gb: 80,
      storage_gb_limit: 200,
    },
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
        destination: { vm_id: "vm-a1", port: 443, protocol: "tcp" },
        description: "HTTPS",
      },
      {
        id: "fw-2",
        action: "allow",
        source: { cidr: "10.42.0.0/16" },
        destination: { vm_id: "vm-a1", port: 5432, protocol: "tcp" },
      },
    ],
  };
}
