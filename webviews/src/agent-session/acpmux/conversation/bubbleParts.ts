// The parts a recorded prompt's bubble draws in their order (UserBubble.tsx), read without React,
// so Find (chatFind.ts) and the row's height estimate (model.ts) read exactly what the bubble draws.
import type { AcpmuxRow, PromptContentPart } from "../model";
import { attachmentPath } from "../fileAttachmentInfo";
import { withoutVideoFrames } from "../composer/videoPrompt";
import { inlineBubbleParts } from "./promptCollapse";

/// The paths of the originals a prompt's images kept (an image the composer converted sends its
/// original file after it).
export function imageOriginals(row: Pick<AcpmuxRow, "retryAttachments">): ReadonlySet<string> {
  return new Set(
    row.retryAttachments?.flatMap((file) => (file.kind === "image" && file.originalPath ? [file.originalPath] : [])),
  );
}

/// A file part that is an image's retained original: drawn as the image, never again as a file.
export function isImageOriginal(part: PromptContentPart, originals: ReadonlySet<string>): boolean {
  return part.kind === "file" && (part.companionOf !== undefined || originals.has(attachmentPath(part.uri) ?? ""));
}

/// The parts a recorded prompt's bubble draws in their order in the pane's default (inline) view, or
/// undefined when it keeps the legacy bands above a bubble of its recorded text: its parts without
/// its videos' frames and notes (which went to the agent only) and its images' retained originals,
/// less the attachments a placed prompt left in the strip, which draw in the band
/// (promptCollapse.ts `inlineBubbleParts`). UserBubble.tsx draws these; Find searches their text and
/// the row's estimate measures them, so neither reads a part the bubble does not draw.
export function bubbleParts(
  row: Pick<AcpmuxRow, "text" | "images" | "inlineParts" | "pasted" | "retryAttachments">,
): PromptContentPart[] | undefined {
  const parts = withoutVideoFrames(row).inlineParts;
  if (!parts) return undefined;
  const originals = imageOriginals(row);
  return inlineBubbleParts(parts.filter((part) => !isImageOriginal(part, originals)));
}
