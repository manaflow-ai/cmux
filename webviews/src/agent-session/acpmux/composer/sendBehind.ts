// A file still attaching never holds the person's Send (Leo, 2026-11-17: "I DRAG AND DROP IT IN WTF
// ARE YOU FUCKING ENCODING", "JUST MAKE IT LOOK LIKE IT'S SENT OR JUST SEND IT"). A dropped, pasted
// or picked file that is not yet a chip (its path still being asked of the host, or its bytes still
// streaming to the chat's machine) goes with the prompt as a stand-in chip: the prompt leaves the
// composer and shows as sent at once, and the chat's client hands it to the agent once every
// stand-in became its chip (direct.ts `send`). A prompt still never goes without the file it was
// sent with (Leo, 2026-11-01: "oh i guess mp4 couldnt get sent"): a file that fails fails the
// prompt's row, with the host's words.
import type { ComposerAttachment } from "../attachments";

/// What a stand-in became: its chip (the link to the file, under the stand-in's id), or why not.
export type BehindSendResult = { chip: ComposerAttachment } | { error: string };

/// Each stand-in still on its way, by chip id. The page's own: a stand-in leaves no copy of a file.
const waiting = new Map<string, Promise<BehindSendResult>>();

/// Registers stand-in `id`, which `result` settles: what the composer's intake makes of its file.
export function sendBehind(id: string, result: Promise<BehindSendResult>): void {
  waiting.set(id, result);
}

/// Whether `chip` is a stand-in still on its way (its file not yet a chip).
export function isBehindSend(chip: Pick<ComposerAttachment, "id">): boolean {
  return waiting.has(chip.id);
}

/// What stand-in `id` became, once it did; taken once. A chip that is no stand-in is itself.
export async function settleBehindSend(chip: ComposerAttachment): Promise<BehindSendResult> {
  const result = waiting.get(chip.id);
  if (!result) return { chip };
  try {
    const settled = await result;
    // Its place in the prompt's text stays the stand-in's.
    return "chip" in settled ? { chip: { ...settled.chip, ...(chip.inline ? { inline: true } : {}) } } : settled;
  } finally {
    waiting.delete(chip.id);
  }
}

/// `attachments` with each stand-in settled: the chips, and the first failure's words, if any.
export async function settleAllBehindSend(
  attachments: readonly ComposerAttachment[],
): Promise<{ attachments: ComposerAttachment[]; error?: string }> {
  const results = await Promise.all(attachments.map(settleBehindSend));
  const error = results.find((result): result is { error: string } => "error" in result)?.error;
  return {
    attachments: results.flatMap((result) => ("chip" in result ? [result.chip] : [])),
    ...(error !== undefined ? { error } : {}),
  };
}
