import type { ComposerAttachment } from "../attachments";

export type HeldPrompt = { text: string; attachments: ComposerAttachment[] };

/// A remote chat starts on its first send: keep a New Tab's image-only prompt while the picked
/// folder becomes the composer draft, so the image is restored into that composer.
export function holdNewTabAttachments(
  held: readonly HeldPrompt[] | undefined,
  attachments: readonly ComposerAttachment[],
): HeldPrompt[] | undefined {
  if (attachments.length === 0) return held ? [...held] : undefined;
  return [...(held ?? []), { text: "", attachments: [...attachments] }];
}
