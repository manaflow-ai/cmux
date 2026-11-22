// The checkpoint review's labels: keys of the pane's string table (checkpoint.*, acpmux/Localizable.xcstrings), in
// every shipped language, so English is never a fallback the user sees.
import { type StringKey, type Translate, translate } from "../i18n";

const CHECKPOINT_KEYS = {
  title: "checkpoint.title",
  createCheckpoint: "checkpoint.createCheckpoint",
  create: "checkpoint.create",
  cancel: "checkpoint.cancel",
  refresh: "checkpoint.refresh",
  loading: "checkpoint.loading",
  creating: "checkpoint.creating",
  untracked: "checkpoint.untracked",
  emptyUntracked: "checkpoint.emptyUntracked",
  included: "checkpoint.included",
  omitted: "checkpoint.omitted",
  unavailable: "checkpoint.unavailable",
  reference: "checkpoint.reference",
  base: "checkpoint.base",
  created: "checkpoint.created",
  expires: "checkpoint.expires",
  pinned: "checkpoint.pinned",
  complete: "checkpoint.complete",
  partial: "checkpoint.partial",
  skipped: "checkpoint.skipped",
  copyReference: "checkpoint.copyReference",
  copied: "checkpoint.copied",
  keep: "checkpoint.keep",
  release: "checkpoint.release",
  manualRetention: "checkpoint.manualRetention",
  failed: "checkpoint.failed",
  retry: "checkpoint.retry",
  recovering: "checkpoint.recovering",
  ignored: "checkpoint.ignored",
  excluded: "checkpoint.excluded",
  tooLarge: "checkpoint.tooLarge",
  notSelected: "checkpoint.notSelected",
  unavailableFile: "checkpoint.unavailableFile",
  bytes: "checkpoint.bytes",
  retained: "checkpoint.retained",
  offline: "checkpoint.offline",
  changed: "checkpoint.changed",
  unsupported: "checkpoint.unsupported",
  noHead: "checkpoint.noHead",
} as const satisfies Record<string, StringKey>;

export type CheckpointStrings = Record<keyof typeof CHECKPOINT_KEYS, string>;

/** The labels in the pane's language (`t` from `useT()` in render; the current language otherwise). */
export function checkpointStrings(t: Translate = translate): CheckpointStrings {
  return Object.fromEntries(Object.entries(CHECKPOINT_KEYS).map(([name, key]) => [name, t(key)])) as CheckpointStrings;
}
