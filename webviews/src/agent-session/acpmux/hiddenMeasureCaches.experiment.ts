// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../experiments/experiment";

/// What a hidden chat page does with the text layout library's word cache (model.ts
/// `dropHiddenMeasureCaches`). That cache grows with the words a chat measured until
/// PREPARED_TEXT_CHARS characters were prepared: at 10k rows it was 10k per-word advance arrays in
/// every chat page, and a window shows one page of many (cmuxterm-hq goals/chats-flat-at-any-length.md).
/// A hidden page draws nothing, so its words are measured again only once it shows.
export const hiddenMeasureCaches = defineExperiment({
  id: "hidden-measure-caches",
  title: "Hidden page word cache",
  description: "A hidden chat page keeps its measured-word cache, or drops it until it shows again.",
  arms: {
    kept: {
      label: "Kept",
      description: "The cache stays until PREPARED_TEXT_CHARS characters were prepared, shown or hidden.",
    },
    dropped: {
      label: "Dropped",
      description: "The cache starts over when the page hides; a shown page measures its words again.",
    },
    "dropped-window-200": {
      label: "Dropped, 200 held",
      description:
        "As Dropped, and a chat left open holds 200 records, not 1,000 (direct/heldRecords.ts HELD_RECORDS).",
    },
  },
  defaultArm: "kept",
});

/// Whether an arm bounds the caches (both arms but `kept`).
export const cachesBounded = (arm: string): boolean => arm !== "kept";
