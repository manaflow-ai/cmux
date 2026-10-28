import type { ComposerAttachment } from "../attachments";

/** A reconnect omits the one-shot seed; only an explicit array replaces the current chips. */
export function restoredDraftAttachments(
  current: ComposerAttachment[] | undefined,
  offered: unknown,
): ComposerAttachment[] | undefined {
  return Array.isArray(offered) ? (offered as ComposerAttachment[]) : current;
}
