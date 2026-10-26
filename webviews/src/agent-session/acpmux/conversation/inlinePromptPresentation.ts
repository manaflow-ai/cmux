// Presentation-only reconciliation for sent prompt content. The daemon's ordered parts decide
// layout; this helper carries optimistic image/video metadata into the echo and hides only a file
// that explicitly names its image block as companionOf.
import type { AcpmuxRow, PromptContentPart } from "../model";
import { recordedPromptParts } from "../inlinePrompt";

export function orderedInlineParts(row: AcpmuxRow): PromptContentPart[] | undefined {
  if (!row.inlineParts) return undefined;
  const recorded = recordedPromptParts(row, row.inlineParts) ?? [];
  const parts = recorded.map((part, index) => {
    const local = row.inlineParts?.[index];
    if (!local || local.kind !== part.kind) return part;
    if (part.kind === "image" && local.kind === "image")
      return {
        ...part,
        ...(local.src ? { src: local.src } : {}),
        ...(local.attachmentId ? { attachmentId: local.attachmentId } : {}),
      };
    if (part.kind !== "text" && part.kind !== "image" && local.kind !== "text" && local.kind !== "image")
      return {
        ...part,
        ...(local.video ? { video: local.video } : {}),
        ...(local.attachmentId ? { attachmentId: local.attachmentId } : {}),
      };
    return part;
  });
  const imageBlocks = new Set(
    parts.flatMap((part) => (part.kind === "image" && part.blockIndex !== undefined ? [part.blockIndex] : [])),
  );
  return parts.filter((part) => part.kind !== "file" || part.companionOf === undefined || !imageBlocks.has(part.companionOf));
}
