// Sample data for the mock provider (dev loop and tests). Shapes follow the `cmux.wire/1` records the
// Cloud app server answers (first-party-apps/cloud/server/src/api/models.rs; vectors
// backend/catalog/cloud-vectors.json). Names, ids and numbers are made up.
import type { CloudMachine, CloudSnapshot, CloudTeam, MigrationStatus } from "./ops";

const DAY = 86_400_000;
const T0 = Date.UTC(2026, 9, 1, 9, 30);

const base = {
  team: "team_personal",
  creator: "user_dev1",
  image: { id: "img_base1", daemon_version: "0.40.0" },
  error: null,
};

export function sampleMachines(): CloudMachine[] {
  return [
    {
      ...base,
      id: "vm_a1",
      name: "api-dev",
      size: { cpu: 4, memory_mb: 8192, disk_mb: 65_536 },
      status: "running",
      host: "host_a1",
      classic: false,
      created_at: T0 - 3 * DAY,
      last_active_at: T0,
      idle_policy: { idle_seconds: 1800 },
      revision: "7",
    },
    {
      ...base,
      id: "vm_b2",
      name: "build-cache",
      size: { cpu: 2, memory_mb: 4096, disk_mb: 16_384 },
      status: "paused",
      host: "host_b2",
      classic: false,
      created_at: T0 - 10 * DAY,
      last_active_at: T0 - DAY,
      idle_policy: { idle_seconds: 900 },
      revision: "4",
    },
    {
      ...base,
      id: "vm_c3",
      name: null,
      size: { cpu: 2, memory_mb: 4096, disk_mb: 16_384 },
      status: "provisioning",
      host: null,
      classic: false,
      created_at: T0,
      last_active_at: null,
      idle_policy: null,
      revision: "1",
    },
    {
      ...base,
      id: "vm_d4",
      name: "old-box",
      size: { cpu: 2, memory_mb: 4096, disk_mb: 16_384 },
      status: "running",
      image: { id: "img_classic", daemon_version: null },
      host: null,
      classic: true,
      created_at: T0 - 90 * DAY,
      last_active_at: T0 - 2 * DAY,
      idle_policy: null,
      revision: "2",
    },
  ];
}

/** The machines whose cmux daemon reports the `fs-v1` capability (file ops on the link). */
export const SAMPLE_FS_MACHINES: readonly string[] = ["vm_a1", "vm_b2"];

export function sampleSnapshots(): CloudSnapshot[] {
  return [
    {
      id: "snap_1",
      machine: "vm_a1",
      name: "before upgrade",
      size_mb: 2048,
      status: "ready",
      created_at: T0 - DAY,
      revision: "3",
    },
    {
      id: "snap_2",
      machine: "vm_a1",
      name: null,
      size_mb: 1024,
      status: "ready",
      created_at: T0 - 2 * DAY,
      revision: "2",
    },
    {
      id: "snap_3",
      machine: "vm_b2",
      name: "warm cache",
      size_mb: 4096,
      status: "ready",
      created_at: T0 - 5 * DAY,
      revision: "1",
    },
  ];
}

/** A small guest tree per machine (finder `fs.*` answers through the server's `Entry`). */
export interface SampleFile {
  kind: "file" | "directory" | "symlink";
  /** File content; a file without one is large (`size` only). */
  text?: string;
  size?: number;
  modifiedAt?: number;
}

export function sampleFiles(): Map<string, SampleFile> {
  return new Map<string, SampleFile>([
    ["/home/cmux", { kind: "directory" }],
    ["/home/cmux/notes.txt", { kind: "file", text: "hello cloud\n", modifiedAt: 1_791_100_000_000 }],
    ["/home/cmux/src", { kind: "directory" }],
    ["/home/cmux/src/main.rs", { kind: "file", text: "fn main() {}\n" }],
    ["/home/cmux/big.bin", { kind: "file", size: 20_971_520 }],
    // A symlink has no size.
    ["/home/cmux/latest", { kind: "symlink" }],
  ]);
}

/** The plan's fixed part; `usage.active` and `usage.saved` come from the mock's machines. */
export interface SamplePlan {
  plan_id: string;
  /** `CloudPlan.upgrade_plan`; dev and staging answer null today. */
  upgrade_plan: string | null;
  max_active: number;
  max_saved: number;
  memory_options_mb: number[];
  locked_memory_options_mb: number[];
  vm_hours_included: number;
  vm_hours_used: number;
  period_end: number;
}

export interface SampleAccount {
  team: string;
  teams: CloudTeam[];
  plan: SamplePlan;
  migration: MigrationStatus;
}

export function sampleAccount(): SampleAccount {
  return {
    team: "team_personal",
    teams: [
      { id: "team_personal", name: "Personal" },
      { id: "team_acme", name: "Acme" },
    ],
    plan: {
      plan_id: "go",
      upgrade_plan: null,
      max_active: 5,
      max_saved: 5,
      // Like the backend vectors: the offered sizes include the locked ones.
      memory_options_mb: [4096, 8192, 16_384, 32_768],
      locked_memory_options_mb: [16_384, 32_768],
      vm_hours_included: 40,
      vm_hours_used: 12.5,
      period_end: T0 + 20 * DAY,
    },
    migration: { state: "available", classic_count: 1, imported: ["vm_d4"] },
  };
}
