// Session uploads use native staging: one bounded base64 chunk crosses the page bridge at a
// time. The native host binds the token to the session/gesture and enforces its storage quota.
// Older hosts keep the legacy upload call; only a missing staging method selects that path.
import { base64 } from "./attachments";

export type UploadResult = { paths: string[] } | { error: string } | undefined;
type Call = (method: string, params: Record<string, unknown>) => Promise<unknown>;
const NOT_TAKEN = new Set(["unsupported", "native.invalid_request"]);
const CHUNK_BYTES = 512 * 1024;
const LEGACY_FRAME_SAFE_BYTES = 24 * 1024 * 1024;

function notTaken(error: unknown): boolean {
  return NOT_TAKEN.has((error as { code?: string } | null)?.code ?? "");
}

function object(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" ? (value as Record<string, unknown>) : {};
}

function uploadedPaths(value: unknown): string[] {
  const reply = object(value);
  if (typeof reply.path === "string" && reply.path.startsWith("/")) return [reply.path];
  return Array.isArray(reply.uploads)
    ? reply.uploads.flatMap((upload: unknown) => {
        const path = object(upload).path;
        return typeof path === "string" && path.startsWith("/") ? [path] : [];
      })
    : [];
}

export async function uploadToMachine(files: File[], call: Call): Promise<UploadResult> {
  if (!files.length || files.some((file) => !file.name)) return undefined;
  const paths: string[] = [];
  const manifest = files.map(({ name, size }) => ({ name, size }));
  let batchToken: string | undefined;
  for (const file of files) {
    let started: unknown;
    try {
      started = await call("chat.upload.begin", {
        name: file.name,
        size: file.size,
        ...(!paths.length && files.length > 1 ? { batch: manifest } : {}),
        ...(batchToken ? { batchToken } : {}),
      });
    } catch (error) {
      if (!paths.length && notTaken(error)) {
        // An old host can only accept one complete JSON frame. Refuse oversized files
        // explicitly instead of rebuilding the removed composer cap as a connection reset.
        if (files.some((entry) => entry.size > LEGACY_FRAME_SAFE_BYTES))
          return { error: "This host cannot stream an attachment this large." };
        return legacyUpload(files, call);
      }
      return { error: error instanceof Error ? error.message : String(error) };
    }
    const begin = object(started);
    if (!paths.length && typeof begin.batchToken === "string" && begin.batchToken) batchToken = begin.batchToken;
    const token = begin.token;
    if (typeof token !== "string" || !token) return { error: "The upload could not be started." };
    try {
      if (begin.size !== file.size || !Number.isSafeInteger(begin.chunkSize) || Number(begin.chunkSize) <= 0)
        throw new Error("The upload could not be started.");
      const chunkSize = Math.min(Number(begin.chunkSize), CHUNK_BYTES);
      for (let offset = 0; offset < file.size;) {
        const end = Math.min(file.size, offset + chunkSize);
        const bytes = new Uint8Array(await file.slice(offset, end).arrayBuffer());
        if (bytes.length !== end - offset) throw new Error("The file could not be read.");
        const answer = object(await call("chat.upload.chunk", { token, offset, data: base64(bytes) }));
        if (answer.offset !== end) throw new Error("The upload could not be completed.");
        offset = end;
      }
      const [path, extra] = uploadedPaths(await call("chat.upload.finish", { token }));
      if (!path || extra) throw new Error("The upload could not be completed.");
      paths.push(path);
    } catch (error) {
      await call("chat.upload.cancel", { token }).catch(() => undefined);
      return { error: error instanceof Error ? error.message : String(error) };
    }
  }
  return { paths };
}

async function legacyUpload(files: File[], call: Call): Promise<UploadResult> {
  try {
    const payload = await Promise.all(
      files.map(async (file) => ({ name: file.name, data: base64(new Uint8Array(await file.arrayBuffer())) })),
    );
    const paths = uploadedPaths(await call("chat.upload", { files: payload }));
    return paths.length === files.length ? { paths } : undefined;
  } catch (error) {
    if (notTaken(error)) return undefined;
    return { error: error instanceof Error ? error.message : String(error) };
  }
}
