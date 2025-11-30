import { z } from "zod";
import morphSnapshotDataJson from "./morph-snapshots.json" with {
  type: "json",
};

const isoDateStringSchema = z
  .string()
  .refine((value) => !Number.isNaN(Date.parse(value)), {
    message: "Invalid ISO date string",
  });

const presetIdSchema = z
  .string()
  .regex(/^[a-z0-9]+_[a-z0-9]+_[a-z0-9]+$/i, {
    message: "presetId must follow <cpu>_<memory>_<disk> format",
  });

export const morphSnapshotVersionSchema = z.object({
  version: z.number().int().positive(),
  snapshotId: z.string().regex(/^snapshot_[a-z0-9]+$/i),
  capturedAt: isoDateStringSchema,
});

export const morphSnapshotPresetSchema = z
  .object({
    presetId: presetIdSchema,
    label: z.string(),
    cpu: z.string(),
    memory: z.string(),
    disk: z.string(),
    description: z.string().optional(),
    versions: z.array(morphSnapshotVersionSchema).min(1).readonly(),
  })
  .superRefine((preset, ctx) => {
    const sortedByVersion = [...preset.versions].sort(
      (a, b) => a.version - b.version,
    );
    for (let index = 1; index < sortedByVersion.length; index += 1) {
      const previous = sortedByVersion[index - 1];
      const current = sortedByVersion[index];
      if (!previous || !current) {
        continue;
      }
      if (current.version <= previous.version) {
        ctx.addIssue({
          code: "custom",
          message: "Versions must be strictly increasing",
          path: ["versions", index, "version"],
        });
        break;
      }
    }
  });

export const morphSnapshotManifestSchema = z.object({
  schemaVersion: z.number().int().positive(),
  updatedAt: isoDateStringSchema,
  presets: z.array(morphSnapshotPresetSchema).min(1),
});

export type MorphSnapshotVersion = z.infer<typeof morphSnapshotVersionSchema>;

export type MorphSnapshotPreset = z.infer<typeof morphSnapshotPresetSchema>;

export interface MorphSnapshotPresetWithLatest extends MorphSnapshotPreset {
  id: MorphSnapshotVersion["snapshotId"];
  latestVersion: MorphSnapshotVersion;
  versions: readonly MorphSnapshotVersion[];
}

export type MorphSnapshotManifest = z.infer<typeof morphSnapshotManifestSchema>;

const sortVersions = (
  versions: readonly MorphSnapshotVersion[],
): MorphSnapshotVersion[] => [...versions].sort((a, b) => a.version - b.version);

const toPresetWithLatest = (
  preset: MorphSnapshotPreset,
): MorphSnapshotPresetWithLatest => {
  const sortedVersions = sortVersions(preset.versions);
  const latestVersion = sortedVersions.length > 0 ? sortedVersions[sortedVersions.length - 1] : undefined;
  if (!latestVersion) {
    throw new Error(`Preset "${preset.presetId}" does not contain versions`);
  }
  return {
    ...preset,
    versions: sortedVersions,
    id: latestVersion.snapshotId,
    latestVersion,
  };
};

const morphSnapshotManifest =
  morphSnapshotManifestSchema.parse(morphSnapshotDataJson);

export const MORPH_SNAPSHOT_MANIFEST: MorphSnapshotManifest =
  morphSnapshotManifest;

const morphSnapshotPresets =
  MORPH_SNAPSHOT_MANIFEST.presets.map(toPresetWithLatest);

export const MORPH_SNAPSHOT_PRESETS: readonly MorphSnapshotPresetWithLatest[] =
  morphSnapshotPresets;

if (MORPH_SNAPSHOT_PRESETS.length === 0) {
  throw new Error("Morph snapshot manifest must include at least one preset");
}

export type MorphSnapshotId =
  (typeof MORPH_SNAPSHOT_PRESETS)[number]["id"];

const firstPreset = MORPH_SNAPSHOT_PRESETS[0];

if (!firstPreset) {
  throw new Error("Morph snapshot manifest must include a default preset");
}

export const DEFAULT_MORPH_SNAPSHOT_ID: MorphSnapshotId = firstPreset.id;
