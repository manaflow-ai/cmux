import type { ComposerHandle } from "./Composer";
import type { Translate } from "./i18n";

/** Prepare an editable suggestion in this chat. The composer keeps any existing draft after it. */
export function prefillStuckNudge(
  composer: Pick<ComposerHandle, "prefill"> | null | undefined,
  diagnosis: string,
  t: Translate,
): void {
  composer?.prefill(`${t("stuck.nudgePrompt", { diagnosis })}\n\n`);
}
