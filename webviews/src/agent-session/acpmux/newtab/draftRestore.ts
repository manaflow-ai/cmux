import type { ComposerAttachment } from "../attachments";

/** A reconnect omits the one-shot seed; only an explicit array replaces the current chips. */
export function restoredDraftAttachments(
  current: ComposerAttachment[] | undefined,
  offered: unknown,
): ComposerAttachment[] | undefined {
  return Array.isArray(offered) ? (offered as ComposerAttachment[]) : current;
}

/** A live wake state wins over the older unsent seed, including an intentional empty list. */
export function wakeDraftAttachments(
  wakeAttachments: ComposerAttachment[] | undefined,
  wakeAttachmentsPresent: boolean,
  offered: ComposerAttachment[] | undefined,
): ComposerAttachment[] | undefined {
  if (wakeAttachmentsPresent) return wakeAttachments;
  return offered?.length ? offered : undefined;
}
