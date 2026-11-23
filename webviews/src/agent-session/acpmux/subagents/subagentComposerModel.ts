import type { ComposerAttachment } from "../attachments";
import { type Draft } from "./subagentDrafts";

/// The prompt after a send failed: the failed message comes back whole, never dropped and never
/// mixed with what was typed since (a timed-out send leaves no failed row in the chat to recover it
/// from). Into an empty prompt it comes back as it was typed, chips and all; over a newer draft, its
/// whole text (pasted chips in their places, `message`) goes above that draft, whose own chips stay
/// its own.
export function afterFailedSend(
  current: Draft,
  sent: { typed: string; held: ComposerAttachment[]; message: string },
): Draft {
  if (!current.text && current.attachments.length === 0) return { text: sent.typed, attachments: sent.held };
  return { text: `${sent.message}\n\n${current.text}`, attachments: current.attachments };
}
