// The parts a recorded prompt's bubble draws in their order (UserBubble.tsx), read without React,
// so Find (chatFind.ts) and the row's height estimate (model.ts) read exactly what the bubble draws.
import type { AcpmuxRow, PromptContentPart } from "../model";
import { isImageOriginal } from "./userBubbleModel";
import { withoutVideoFrames } from "../composer/videoPrompt";
import { inlineBubbleParts, isStripMedia } from "./promptCollapse";
import { readsAsText } from "./inlinePromptContentModel";

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

/// The parts a recorded prompt's bubble draws in their order (`bubbleLayout`), or undefined when it
/// keeps the legacy bands above a bubble of its recorded text: its parts without its videos' frames
/// and notes (which went to the agent only), its images' retained originals and its attachments,
/// which draw in the block above it. UserBubble.tsx draws these; Find searches their text, so it
/// never reads a part the bubble does not draw, nor misses words the block's leaving joined.
export function bubbleParts(
  row: Pick<AcpmuxRow, "text" | "images" | "inlineParts" | "pasted" | "retryAttachments">,
): PromptContentPart[] | undefined {
  return bubbleLayout(row)?.parts;
}

/// A prompt drawn in its parts' order as UserBubble.tsx lays it out: `band`, every attachment it
/// sent, in one block above the bubble at the sent tile's size, and `parts`, the bubble's text
/// (typed words, pastes, a text file's body behind its chip) as plain flow below it. A sent message
/// draws so in every attachment view (Leo, 2026-11-17: "Attachments render inline in the middle of
/// the text line, at odd sizes. Put them in a block above the text."); the view
/// (composerSettings.ts `attachmentView`) places attachments in the composer only. Undefined for a
/// prompt that keeps the legacy bands. The row's estimate (model.ts) measures both, so the row does
/// not shift when it mounts.
export function bubbleLayout(
  row: Pick<AcpmuxRow, "text" | "images" | "inlineParts" | "pasted" | "retryAttachments">,
): { parts: PromptContentPart[]; band: Exclude<PromptContentPart, { kind: "text" }>[] } | undefined {
  const recorded = withoutVideoFrames(row).inlineParts;
  if (!recorded) return undefined;
  const originals = imageOriginals(row);
  const parts = recorded.filter((part) => !isImageOriginal(part, originals));
  if (!inlineBubbleParts(parts)) return undefined;
  return { parts: parts.filter((part) => !isStripMedia(part)), band: parts.filter(isStripMedia) };
}
