// Attachments too large to go inline in a prompt with no saved copy (an older draft's PDF, a
// recording, an image whose original did not upload) upload at the person's Send and go as links
// (promptBudget.ts `uploadsToFit`). The Send is one gesture, and the prompt needs it: so the page
// reserves it as the prompt's ticket first (`transport.gesture`), and each `chat.upload.begin`
// carries that ticket, which the host holds while the upload runs instead of spending a gesture
// (CmuxNextAgentPane AgentPaneModel+UploadHolds.swift). The prompt then goes under the ticket.
import { savedAttachment, type ComposerAttachment } from "./attachments";
import { uploadToMachine } from "./cloudUploads";
import { translate } from "./i18n";

export type SendPrompt = { sessionId: string; promptId: string; ticket?: string };
export type SendUploadResult = { ticket: string; attachments: ComposerAttachment[] } | { error: string };
type Call = (method: string, params: Record<string, unknown>) => Promise<unknown>;

/// Uploads `chips` to the chat's machine under the Send's ticket (`prompt.ticket` when the prompt
/// already holds one, a held prompt's; else reserved now) and answers each as the link to its copy,
/// in its place (its id kept), with the ticket the prompt goes under; or the upload's error.
export async function uploadForSend(
  chips: ComposerAttachment[],
  prompt: SendPrompt,
  call: Call,
): Promise<SendUploadResult> {
  let ticket = prompt.ticket;
  if (!ticket) {
    const reply = await call("transport.gesture", {
      intent: { method: "session/prompt", params: { promptId: prompt.promptId, sessionId: prompt.sessionId } },
    }).catch(() => undefined);
    const reserved = (reply as { ticket?: unknown } | undefined)?.ticket;
    if (typeof reserved !== "string" || !reserved) return { error: translate("upload.notStarted") };
    ticket = reserved;
  }
  const files = chips.map((chip) => new File([bytesOf(chip.data ?? "")], chip.name, { type: chip.mimeType }));
  const sent = await uploadToMachine(files, call, undefined, {
    sessionId: prompt.sessionId,
    promptId: prompt.promptId,
    ticket,
  }).catch((failure: unknown) => ({ error: failure instanceof Error ? failure.message : String(failure) }));
  if (sent && "error" in sent) return { error: sent.error };
  const paths = sent?.paths ?? [];
  if (paths.length !== chips.length || paths.some((path) => !path)) return { error: translate("upload.notCompleted") };
  return {
    ticket,
    attachments: chips.map((chip, index) => ({
      ...savedAttachment(paths[index]!, chip.name),
      id: chip.id,
      ...(chip.inline ? { inline: true } : {}),
      mimeType: chip.mimeType,
      size: chip.size,
    })),
  };
}

function bytesOf(data: string): Uint8Array<ArrayBuffer> {
  const binary = atob(data);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index++) bytes[index] = binary.charCodeAt(index);
  return bytes;
}
