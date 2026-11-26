import type { AgentSessionAttachment } from "./types";
import { escapeMarkdownDestination, escapeMarkdownLabel } from "./markdownEscapes";

export function promptTextWithAttachments(input: string, attachments: AgentSessionAttachment[]): string {
  const attachmentText = attachments
    .map((attachment) => `[${escapeMarkdownLabel(attachment.label)}](${escapeMarkdownDestination(attachment.path)})`)
    .join(" ");
  if (!attachmentText) {
    return input;
  }
  return input.trim().length > 0 ? `${attachmentText}\n\n${input}` : attachmentText;
}
