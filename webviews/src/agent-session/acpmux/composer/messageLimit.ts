// How many attachments one message of a chat takes, and which of the staged ones go when it is sent
// (Leo 2026-10-22: "why only 10 attachments per message? is that a model limitation or..."). The 10
// was the composer's own; the models take far more. One table, by the chat's harness: the number
// its model API takes in one request, from the provider's docs (read 2026-10-22). Whatever the
// harness, a prompt crosses acpmux as one JSON-RPC message (acpmux `rpc::MAX_MESSAGE_BYTES`, 15 MiB;
// past it the WebSocket resets every chat on the connection), so the attachments that go inline share
// MESSAGE_ATTACHMENT_BYTES of it. Past either, the rest stay staged for the next message.
import type { ComposerAttachment } from "../attachments";

export type MessageLimit = { count: number; bytes: number };

/// The attachments one request takes, by the harness's family (acpmux `family`, else its id).
const PER_REQUEST: Readonly<Record<string, (contextWindow: number | undefined) => number>> = {
  // platform.claude.com/docs/en/build-with-claude/vision: 100 images a request for a 200k-token
  // window, 600 for 1M; past 20 each must be at most 2000 px a side (MAX_IMAGE_SIDE is). Claude Code
  // drops a conversation's oldest images past the same numbers.
  claude: (window) => (window !== undefined && window >= 1_000_000 ? 600 : 100),
  // developers.openai.com/api/docs/guides/images-vision: up to 1,500 images a request.
  codex: () => 1500,
  // ai.google.dev/gemini-api/docs/image-understanding: at most 3,600 image files a request.
  gemini: () => 3600,
};
/// A harness whose model the table doesn't know (OpenCode, pi, a custom agent): claude.ai's 20 a
/// message, the lowest any of these providers documents.
const UNKNOWN_HARNESS = 20;

/// The bytes the attachments of one prompt may have on the wire: acpmux's 15 MiB message less 1 MiB
/// for the prompt's text and the JSON around it. A 10 MiB PDF (MAX_DOCUMENT_BYTES) fits alone.
export const MESSAGE_ATTACHMENT_BYTES = 14 * 1024 * 1024;

/// The most chips a chat's composer holds at once, staged across messages; each image is at most
/// IMAGE_BUDGET_BYTES, so the page holds at most about 200 MiB of them.
export const MAX_STAGED_ATTACHMENTS = 100;

export function messageLimit(chat: { family?: string; harness?: string; contextWindow?: number }): MessageLimit {
  const perRequest = PER_REQUEST[chat.family ?? ""] ?? PER_REQUEST[chat.harness ?? ""];
  return { count: perRequest ? perRequest(chat.contextWindow) : UNKNOWN_HARNESS, bytes: MESSAGE_ATTACHMENT_BYTES };
}

/// `bytes` as whole megabytes in the reader's language ("14 MB"), for the composer's note.
export function megabytes(bytes: number, language: string): string {
  return new Intl.NumberFormat(language, { style: "unit", unit: "megabyte", maximumFractionDigits: 0 }).format(
    bytes / (1024 * 1024),
  );
}

/// What an attachment adds to the prompt's message: its base64 bytes, its text (at most 3 UTF-8
/// bytes a UTF-16 unit, before JSON escaping), or a link's path.
function wireBytes(attachment: ComposerAttachment): number {
  return (attachment.data?.length ?? 0) + (attachment.text?.length ?? 0) * 3 + (attachment.path?.length ?? 0);
}

export type MessageSplit = { now: ComposerAttachment[]; later: ComposerAttachment[]; over?: "count" | "bytes" };

/// The staged attachments that go with this message (the first ones, in order, within `limit`; the
/// first always goes), the ones that wait for the next, and which limit held them back.
export function splitForMessage(attachments: readonly ComposerAttachment[], limit: MessageLimit): MessageSplit {
  let bytes = 0;
  for (const [index, attachment] of attachments.entries()) {
    if (index >= limit.count) return split(attachments, index, "count");
    bytes += wireBytes(attachment);
    if (index > 0 && bytes > limit.bytes) return split(attachments, index, "bytes");
  }
  return { now: [...attachments], later: [] };
}

function split(attachments: readonly ComposerAttachment[], at: number, over: "count" | "bytes"): MessageSplit {
  return { now: attachments.slice(0, at), later: attachments.slice(at), over };
}
