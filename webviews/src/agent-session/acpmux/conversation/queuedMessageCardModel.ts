import type { AcpmuxRow } from "../model";
import { recordedFiles } from "./userBubbleModel";
import type { FileAttachmentInfo } from "../FileAttachment";

/// Where a held message's Approve and Decline sit: in the line's action area (`inline`, the pick),
/// in a compact bar under the message (`bar`), or in a ⋯ menu beside the label (`menu`). The
/// gallery compares them through `<html data-held-card-look>`; the app sets none.
export type HeldLook = "inline" | "bar" | "menu";
export function heldLook(root: { dataset: DOMStringMap } | undefined = globalThis.document?.documentElement): HeldLook {
  const value = root?.dataset.heldCardLook;
  return value === "bar" || value === "menu" ? value : "inline";
}

/// Everything a held message sends beyond its text and images, so the owner approves what they
/// see: its resource links as a sent prompt draws them (UserBubble.tsx `recordedFiles`), and its
/// documents and audio as the same file chips (a sent prompt's own bubble has them in the
/// composer's attachments instead).
export function heldFiles(parts: AcpmuxRow["inlineParts"]): FileAttachmentInfo[] {
  const media = (parts ?? []).flatMap((part): FileAttachmentInfo[] =>
    (part.kind === "document" || part.kind === "audio") && part.companionOf === undefined
      ? [
          {
            name: part.name,
            ...(part.mimeType ? { mimeType: part.mimeType } : {}),
            ...(part.size ? { size: part.size } : {}),
          },
        ]
      : [],
  );
  return [...(recordedFiles(parts) ?? []), ...media];
}
