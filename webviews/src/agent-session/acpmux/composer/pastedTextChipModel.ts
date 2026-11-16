// The pasted text chip's data (composer/PastedTextChip.tsx): which design draws it, and its label's
// parts. Kept out of the component's module so that module exports only components (Fast Refresh).
import { createContext } from "react";
import { pasteLines } from "../conversation/promptCollapse";
import type { Translate } from "../i18n";

/// How the chip opens its text, and how it looks closed (gallery agent-pane.composer-paste-chip):
/// - `sheet` (ships): a compact row (a page glyph, the paste's first words, its label) that opens
///   the whole text in a viewer sheet over the pane, Edit in Prompt and Keep as .txt in its bar.
/// - `expand`: the same row, opening a panel under itself in the composer with the text and both
///   actions.
/// - `tile`: a small tile (the glyph, the name over its size, no words) that opens the same sheet.
export type PasteChipDesign = "sheet" | "expand" | "tile";

/// The design the composer draws. Only the gallery sets another, to compare them.
export const PASTE_CHIP_DESIGN: PasteChipDesign = "sheet";

/// The design in effect under a provider; the composer has none and draws the default.
export const PasteChipDesignContext = createContext<PasteChipDesign>(PASTE_CHIP_DESIGN);

/// The most characters of the paste the closed chip's preview keeps: one line of the widest chip
/// and more, so a long paragraph fills it; it fades out at the chip's edge.
export const PASTE_CHIP_PREVIEW_CHARS = 480;

/// A paste's size as the parts its label shows after its name, in the order the label drops them
/// from the end when it has no room: its lines (when more than one: one long paragraph is "1 line"
/// and says nothing), then its characters ("42 lines", "1.8K characters").
export function pastedSizeParts(t: Translate, language: string, text: string): string[] {
  const lines = pasteLines(text);
  const chars = t("composer.pastedChars", {
    count: new Intl.NumberFormat(language, { notation: "compact", maximumFractionDigits: 1 }).format(text.length),
  });
  if (lines < 2) return [chars];
  return [t("transcript.pastedLines", { n: lines, count: new Intl.NumberFormat(language).format(lines) }), chars];
}

/// The parts of a label joined as one line reads them ("42 lines · 1.8K characters").
export const LABEL_SEPARATOR = " · ";
