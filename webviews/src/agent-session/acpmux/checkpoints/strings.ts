export const checkpointStrings = {
  title: "Repository checkpoint",
  createCheckpoint: "Create checkpoint",
  create: "Create",
  cancel: "Cancel",
  refresh: "Refresh",
  loading: "Loading checkpoint options…",
  creating: "Creating checkpoint…",
  untracked: "Untracked files",
  emptyUntracked: "No eligible untracked files",
  included: "Included",
  omitted: "Omitted",
  unavailable: "Unavailable",
  reference: "Reference",
  base: "Base",
  created: "Created",
  expires: "Expires",
  pinned: "Pinned",
  complete: "Complete",
  partial: "Partial checkpoint",
  skipped: "Skipped files",
  copyReference: "Copy reference",
  copied: "Copied",
  keep: "Keep checkpoint",
  release: "Release pin",
  manualRetention: "Use Keep checkpoint before sharing this reference in a manual handoff.",
  failed: "Couldn’t complete this checkpoint request.",
  retry: "Retry",
  recovering: "Checking the saved checkpoint…",
  ignored: "Ignored",
  excluded: "Excluded",
  tooLarge: "Over the file size limit",
  notSelected: "Not selected",
  unavailableFile: "Unavailable file",
  bytes: "Bytes",
  retained: "Retained",
  offline: "Reconnect before creating a checkpoint.",
  changed: "The repository changed. Refresh the checkpoint options.",
  unsupported: "Repository checkpoints are unavailable for this session.",
  noHead: "No commit yet",
};
export type CheckpointStrings = typeof checkpointStrings;
export function localizedCheckpointStrings(value: unknown): CheckpointStrings {
  const strings = { ...checkpointStrings };
  if (value && typeof value === "object")
    for (const key of Object.keys(strings) as (keyof CheckpointStrings)[]) {
      const translated = (value as Record<string, unknown>)[key];
      if (typeof translated === "string" && translated.trim()) strings[key] = translated;
    }
  return strings;
}
