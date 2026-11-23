// The parts a recorded prompt's bubble draws in their order (UserBubble.tsx), read without React,
// so Find (chatFind.ts) and the row's height estimate (model.ts) read exactly what the bubble draws.
import type { AcpmuxRow, PromptContentPart } from "../model";
import { isImageOriginal } from "./userBubbleModel";
import { withoutVideoFrames } from "../composer/videoPrompt";
import { inlineBubbleParts, isStripMedia } from "./promptCollapse";
import { readsAsText } from "./inlinePromptContentModel";
import type { AttachmentView } from "../composerSettings";

/// The paths of the originals a prompt's images kept (an image the composer converted sends its
/// original file after it).
export function imageOriginals(row: Pick<AcpmuxRow, "retryAttachments">): ReadonlySet<string> {
  return new Set(
    row.retryAttachments?.flatMap((file) => (file.kind === "image" && file.originalPath ? [file.originalPath] : [])),
  );
}

/// Whether a prompt gives its bubble nothing to read: blank text, and every recorded part an
/// attachment or blank text. UserBubble.tsx draws such a prompt's attachments in the strip above no
/// bubble, in every attachment view, and the row's height estimate (model.ts) reserves that strip,
/// so the two agree. A legacy prompt whose parts are only its files (direct.ts keeps them for the
/// band) keeps its typed text, so its bubble draws.
export function attachmentOnly(parts: readonly PromptContentPart[] | undefined, text: string | undefined): boolean {
  return !text?.trim() && Boolean(parts?.length) && parts!.every((part) => !readsAsText(part));
}

/// `attachmentOnly` of a row's text and recorded parts as UserBubble.tsx reads them (less its
/// images' retained originals).
export function attachmentOnlyPrompt(row: Pick<AcpmuxRow, "text" | "inlineParts" | "retryAttachments">): boolean {
  if (!row.inlineParts?.length || row.text?.trim()) return false;
  const originals = imageOriginals(row);
  return attachmentOnly(
    row.inlineParts.filter((part) => !isImageOriginal(part, originals)),
    row.text,
  );
}

/// The parts a recorded prompt's bubble draws in their order in the pane's attachment view
/// (`bubbleLayout`), or undefined when it keeps the legacy bands above a bubble of its recorded text:
/// its parts without its videos' frames and notes (which went to the agent only) and its images'
/// retained originals, less the attachments that draw in the band above it (every one in the strip
/// view; a placed prompt's unmarked ones in the others, promptCollapse.ts `inlineBubbleParts`).
/// UserBubble.tsx draws these; Find searches their text, so it never reads a part the bubble does
/// not draw, nor misses words the band's leaving joined.
export function bubbleParts(
  row: Pick<AcpmuxRow, "text" | "images" | "inlineParts" | "pasted" | "retryAttachments">,
  view: AttachmentView,
): PromptContentPart[] | undefined {
  return bubbleLayout(row, view)?.parts;
}

/// A prompt drawn in its parts' order as UserBubble.tsx lays it out in the pane's attachment view
/// (composerSettings.ts `attachmentView`): `parts` in its bubble, and `band`, the attachments it
/// draws in the row above the bubble. The strip view draws every attachment in that row and leaves
/// the bubble its text; the others ("both" draws as "inline") leave only a placed prompt's unmarked
/// attachments there. Undefined for a prompt that keeps the legacy bands. The row's estimate
/// (model.ts) measures both, so a strip prompt is not estimated as an inline one.
export function bubbleLayout(
  row: Pick<AcpmuxRow, "text" | "images" | "inlineParts" | "pasted" | "retryAttachments">,
  view: AttachmentView,
): { parts: PromptContentPart[]; band: Exclude<PromptContentPart, { kind: "text" }>[] } | undefined {
  const recorded = withoutVideoFrames(row).inlineParts;
  if (!recorded) return undefined;
  const originals = imageOriginals(row);
  const parts = recorded.filter((part) => !isImageOriginal(part, originals));
  const inline = inlineBubbleParts(parts);
  if (!inline) return undefined;
  if (view === "strip") return { parts: parts.filter((part) => !isStripMedia(part)), band: parts.filter(isStripMedia) };
  return { parts: inline, band: parts.filter(isStripMedia).filter((part) => !inline.includes(part)) };
}
