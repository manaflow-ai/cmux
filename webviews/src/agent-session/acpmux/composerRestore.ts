import type { ComposerAttachment } from "./attachments";

type ComposerRestoreHandle = {
  restore(text: string, attachments: ComposerAttachment[]): void;
};

type HeldBackPrompt = { text: string; attachments: ComposerAttachment[] };

/// Restore a prompt after an async queue action, preserving it while the composer is unmounted.
export function restoreComposerDraft(
  composer: { current: ComposerRestoreHandle | null },
  heldBack: { current: HeldBackPrompt[] | undefined },
  text: string,
  attachments: ComposerAttachment[],
): void {
  const handle = composer.current;
  if (handle) {
    handle.restore(text, attachments);
    return;
  }
  heldBack.current = [...(heldBack.current ?? []), { text, attachments }];
}
