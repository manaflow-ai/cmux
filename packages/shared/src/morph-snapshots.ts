export interface MorphSnapshotPreset {
  id: string;
  label: string;
  cpu: string;
  memory: string;
  disk: string;
  description?: string;
}

export const MORPH_SNAPSHOT_PRESETS = [
  {
    id: "snapshot_cj0nsc2j",
    label: "Standard workspace",
    cpu: "4 vCPU",
    memory: "16 GB RAM",
    disk: "48 GB SSD",
    description:
      "Great default for day-to-day work. Balanced CPU, memory, and storage.",
  },
  {
    id: "snapshot_qbpom27i",
    label: "Performance workspace",
    cpu: "8 vCPU",
    memory: "32 GB RAM",
    disk: "48 GB SSD",
    description: "Extra headroom for larger codebases or heavier workloads.",
  },
] as const satisfies readonly MorphSnapshotPreset[];

export type MorphSnapshotId = (typeof MORPH_SNAPSHOT_PRESETS)[number]["id"];

export const DEFAULT_MORPH_SNAPSHOT_ID: MorphSnapshotId =
  MORPH_SNAPSHOT_PRESETS[0].id;
