// Stub: filled by the fix.
import type { ComposerAttachment } from "./attachments";

export type SendPrompt = { sessionId: string; promptId: string; ticket?: string };
export type SendUploadResult = { ticket: string; attachments: ComposerAttachment[] } | { error: string };
type Call = (method: string, params: Record<string, unknown>) => Promise<unknown>;

export async function uploadForSend(
  _chips: ComposerAttachment[],
  _prompt: SendPrompt,
  _call: Call,
): Promise<SendUploadResult> {
  return { error: "not built" };
}
