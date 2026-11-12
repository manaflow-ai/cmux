// The loading look of a pasted attachment's tile (composer/pasteLoading.tsx): its classes and the
// experiment arm this page runs (pastePlaceholder.experiment.ts).
import { useState } from "react";
import { experimentArm } from "../../../experiments/experiment";
import { pastePlaceholderLook } from "./pastePlaceholder.experiment";

/// The classes a loading tile adds: the composer's own glass material (src/ui/glass/glass.css), never
/// a solid fill, and the loading look (composerAttachments.css "Loading").
export const PASTE_LOADING_CLASS = "ui-glass ui-glass-material acpmux-paste-loading";

/// The loading look this page runs, read once per tile.
export function usePasteLoadingLook() {
  const [look] = useState(() => experimentArm(pastePlaceholderLook));
  return look;
}

/// Whether `look` draws the chip itself from the first frame (the `chip` arms), never a loading tile.
export function isChipLook(look: string): boolean {
  return look === "chip" || look.startsWith("chip-");
}
