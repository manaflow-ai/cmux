import type { PromptBlock, PromptEntry } from "./attachments";
import type { PromptUploadTransport, UploadReply } from "./nativePromptUpload";
export { createNativePromptUploadTransport, type PromptUploadTransport } from "./nativePromptUpload";
export const PROMPT_UPLOADS_FEATURE = "promptUploads";
export function nativePromptUploadsAvailable(): boolean {
  return (globalThis as typeof globalThis & { __cmuxNativePromptUploads?: boolean }).__cmuxNativePromptUploads === true;
}
export type PromptUploadRef = { uploadId: string; fileName: string };
export type UploadRecord = PromptUploadRef & { source: string; mimeType: string; size: number };
export type UploadToken = { token: string; source: string; fileName: string; mimeType: string; size: number };
type PrepareInput = {
  entries: PromptEntry[];
  blockIndexes?: Map<number, number>;
  features: readonly string[];
  sessionId: string;
  promptId?: string;
  ticket?: string;
  transport?: PromptUploadTransport;
  cache: Map<string, UploadRecord>;
  tokenCache?: Map<string, UploadToken>;
  isCancelled?: () => boolean;
};
type UploadBlobScope = typeof globalThis & { __cmuxUploadBlobs?: Map<string, Blob> };
const tokenOwners = new Map<string, string>();
const activeTokens = new Set<string>();
const inFlight = new Map<string, Promise<UploadReply>>();
const waiters = new Map<string, number>();
const discardedTokens = new Set<string>();
const cancelTokens = new Map<string, () => void>();
const tokenRecords = new Map<string, () => void>();
function blobRegistry(): Map<string, Blob> {
  return ((globalThis as UploadBlobScope).__cmuxUploadBlobs ??= new Map());
}
export function registerPromptUploadBlob(blob: Blob, token = crypto.randomUUID()): string {
  blobRegistry().set(token, blob);
  return token;
}
export function releasePromptUploadBlob(token: string, cancel = false): void {
  if (cancel) {
    cancelTokens.get(token)?.();
    tokenRecords.get(token)?.();
  }
  tokenRecords.delete(token);
  cancelTokens.delete(token);
  blobRegistry().delete(token);
  tokenOwners.delete(token);
  discardedTokens.delete(token);
}
function discardToken(token: string, cancel = true): void {
  if (activeTokens.has(token)) {
    if (cancel && (waiters.get(token) ?? 0) > 1) return;
    discardedTokens.add(token);
    if (cancel) cancelTokens.get(token)?.();
  } else releasePromptUploadBlob(token, cancel);
}
export function releasePromptUploadAttachments(ids: readonly string[], cancel = true): void {
  for (const [token, id] of tokenOwners) if (ids.includes(id)) discardToken(token, cancel);
}
function base64Size(data: string): number {
  const padding = data.endsWith("==") ? 2 : data.endsWith("=") ? 1 : 0;
  return Math.max(0, Math.floor((data.length * 3) / 4) - padding);
}
function base64ToBlob(data: string, type: string): Blob {
  const parts: BlobPart[] = [];
  for (let at = 0; at < data.length; at += 1024 * 1024) {
    const binary = atob(data.slice(at, at + 1024 * 1024));
    parts.push(Uint8Array.from(binary, (char) => char.charCodeAt(0)));
  }
  return new Blob(parts, { type });
}
function completedReply(reply: UploadReply, size: number): PromptUploadRef {
  if (!reply || typeof reply.uploadId !== "string" || !reply.uploadId)
    throw new Error("The host returned an invalid upload");
  if ((reply.size !== undefined && reply.size !== size) || (reply.offset !== undefined && reply.offset !== size))
    throw new Error("The host returned an incomplete upload");
  return { uploadId: reply.uploadId, fileName: "" };
}
export async function preparePromptUploads({
  entries,
  blockIndexes,
  features,
  sessionId,
  promptId,
  ticket,
  transport,
  cache,
  tokenCache = new Map(),
  isCancelled,
}: PrepareInput): Promise<PromptBlock[]> {
  blockIndexes?.clear();
  if (!features.includes(PROMPT_UPLOADS_FEATURE)) {
    entries.forEach((_, index) => blockIndexes?.set(index, index));
    return entries.map((entry) => entry.block);
  }
  if (!transport) throw new Error("Prompt upload transport is unavailable");
  const ensureOpen = () => {
    if (isCancelled?.()) throw new Error("The upload client is closed");
  };
  const result: PromptBlock[] = [];
  const uploaded = new Set<string>();
  for (let index = 0; index < entries.length; index += 1) {
    ensureOpen();
    const { block, attachment, companionOf } = entries[index]!;
    if (companionOf && uploaded.has(companionOf)) continue;
    blockIndexes?.set(index, result.length);
    if ((block.type !== "image" && block.type !== "document" && block.type !== "audio") || !block.data) {
      result.push(block);
      continue;
    }
    const source = block.data;
    const size = base64Size(source);
    const mimeType = block.mimeType;
    const fileName = ("name" in block && block.name) || attachment?.name || `attachment-${index}.bin`;
    const key = `${sessionId}:${attachment?.id ?? index}`;
    const matches = (value: UploadRecord | UploadToken) =>
      value.source === source && value.fileName === fileName && value.mimeType === mimeType;
    let record = cache.get(key);
    if (record && !matches(record)) {
      cache.delete(key);
      record = undefined;
    }
    if (!record) {
      let pending = tokenCache.get(key);
      if (pending && (!matches(pending) || !blobRegistry().has(pending.token))) {
        discardToken(pending.token);
        tokenCache.delete(key);
        pending = undefined;
      }
      const token = pending?.token ?? registerPromptUploadBlob(base64ToBlob(source, mimeType));
      if (attachment) tokenOwners.set(token, attachment.id);
      tokenCache.set(key, { token, source, fileName, mimeType, size });
      activeTokens.add(token);
      const sending =
        inFlight.get(token) ?? transport.beginBlob({ sessionId, fileName, mimeType, size, token, promptId, ticket });
      if (!inFlight.has(token) && transport.cancelBlob)
        cancelTokens.set(token, () => {
          void transport.cancelBlob!(token).catch(() => undefined);
        });
      inFlight.set(token, sending);
      waiters.set(token, (waiters.get(token) ?? 0) + 1);
      const forget = () => {
        releasePromptUploadBlob(token);
        if (tokenCache.get(key)?.token === token) tokenCache.delete(key);
      };
      let ref: PromptUploadRef;
      try {
        const reply = await sending;
        ensureOpen();
        ref = completedReply(reply, size);
      } catch (error) {
        if (discardedTokens.has(token) && waiters.get(token) === 1) forget();
        throw error;
      } finally {
        const left = (waiters.get(token) ?? 1) - 1;
        if (left) waiters.set(token, left);
        else {
          waiters.delete(token);
          if (inFlight.get(token) === sending) {
            inFlight.delete(token);
            activeTokens.delete(token);
          }
        }
      }
      record = { ...ref, fileName, source, mimeType, size };
      if (tokenCache.get(key)?.token === token) {
        cache.set(key, record);
        tokenRecords.set(token, () => {
          if (cache.get(key) === record) cache.delete(key);
        });
      }
      if (discardedTokens.has(token) && !waiters.has(token)) forget();
    }
    const upload = { uploadId: record.uploadId, fileName: record.fileName };
    result.push(
      block.type === "image"
        ? { type: "image", mimeType, name: block.name, _meta: { acpmux: { upload } } }
        : {
            type: "resource_link",
            uri: `acpmux-upload:${record.uploadId}`,
            name: fileName,
            _meta: { acpmux: { upload } },
          },
    );
    if (attachment) uploaded.add(attachment.id);
  }
  return result;
}
