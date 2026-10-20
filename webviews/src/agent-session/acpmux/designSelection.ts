import type { ComposerAttachment } from "./attachments";

/// Design mode's card for one highlight (Swift `BrowserDesignModeCard`), pushed by the host as the
/// `designSelection` event (plans/cmux-next/design-mode-DESIGN.md).
export type DesignSelection = {
  id: string;
  name: string;
  text: string;
  image?: { mimeType: string; data: string };
};

/// The composer chips for a highlight; none for a value that is not one.
export function designSelectionChips(_value: unknown): ComposerAttachment[] {
  return [];
}
