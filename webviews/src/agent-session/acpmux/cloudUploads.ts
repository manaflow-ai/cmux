// Session uploads use native staging: one bounded base64 chunk crosses the page bridge at a
// time. The native host binds the token to the session/gesture and enforces its storage quota.
// Older hosts keep the legacy upload call; only a missing staging method selects that path.
import { base64 } from "./attachments";

export type UploadResult = { paths: string[] } | { error: string } | undefined;
type Call = (method: string, params: Record<string, unknown>) => Promise<unknown>;
const NOT_TAKEN = new Set(["unsupported", "native.invalid_request"]);
const CHUNK_BYTES = 512 * 1024;
const LEGACY_FRAME_SAFE_BYTES = 24 * 1024 * 1024;

/// How long one step of an upload (begin, one chunk, finish) may wait for the host: past it the
/// upload fails with a note and its chip offers Retry, never loading forever (Leo, 2026-10-24: "I
/// can't even cancel these... supposedly in-progress attachments").
export const UPLOAD_STEP_DEADLINE_MS = 30_000;
export const UPLOAD_TIMED_OUT = "The upload timed out: the app did not answer.";

/// `call`, refused with UPLOAD_TIMED_OUT when the host does not answer within `ms`.
export function callWithin(call: Call, ms = UPLOAD_STEP_DEADLINE_MS): Call {
  return (method, params) =>
    new Promise((resolve, reject) => {
      let late = false;
      const timer = setTimeout(() => {
        late = true;
        reject(new Error(UPLOAD_TIMED_OUT));
      }, ms);
      call(method, params).then(
        (value) => {
          clearTimeout(timer);
          // An upload the host started after the page gave up on it: the host drops its stage.
          const token = (value as { token?: unknown } | null)?.token;
          if (late && method === "chat.upload.begin" && typeof token === "string")
            void call("chat.upload.cancel", { token }).catch(() => undefined);
          resolve(value);
        },
        (error: unknown) => {
          clearTimeout(timer);
          reject(error);
        },
      );
    });
}

/// Thrown inside an upload the person cancelled; never a note.
const CANCELLED = new Error("cancelled");

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

/// `cancelled(index)`: the person took file `index` away (its tile's x). Checked before each chunk:
/// its upload stops there, the host drops what it staged, and its path is "" (Leo, 2026-10-25:
/// "...from cancelling the thing").
export async function uploadToMachine(
  files: File[],
  host: Call,
  cancelled: (index: number) => boolean = () => false,
): Promise<UploadResult> {
  const call = callWithin(host);
  if (!files.length || files.some((file) => !file.name)) return undefined;
  const paths: string[] = [];
  const manifest = files.map(({ name, size }) => ({ name, size }));
  let batchToken: string | undefined;
  /// Whether the host took a begin (an older host refuses the first, which selects the one-frame upload).
  let begun = false;
  for (const [index, file] of files.entries()) {
    // A file cancelled before its upload begins is begun all the same and cancelled at once: a
    // batch's host takes its files in the manifest's order, so skipping one would stop the rest.
    let started: unknown;
    try {
      started = await call("chat.upload.begin", {
        name: file.name,
        size: file.size,
        ...(index === 0 && files.length > 1 ? { batch: manifest } : {}),
        ...(batchToken ? { batchToken } : {}),
      });
    } catch (error) {
      if (!begun && notTaken(error)) {
        // An old host can only accept one complete JSON frame. Refuse oversized files
        // explicitly instead of rebuilding the removed composer cap as a connection reset.
        if (files.some((entry, at) => !cancelled(at) && entry.size > LEGACY_FRAME_SAFE_BYTES))
          return { error: "This host cannot stream an attachment this large." };
        return legacyUpload(files, call, cancelled);
      }
      return { error: error instanceof Error ? error.message : String(error) };
    }
    begun = true;
    const begin = object(started);
    if (index === 0 && typeof begin.batchToken === "string" && begin.batchToken) batchToken = begin.batchToken;
    const token = begin.token;
    if (typeof token !== "string" || !token) return { error: "The upload could not be started." };
    try {
      if (begin.size !== file.size || !Number.isSafeInteger(begin.chunkSize) || Number(begin.chunkSize) <= 0)
        throw new Error("The upload could not be started.");
      const chunkSize = Math.min(Number(begin.chunkSize), CHUNK_BYTES);
      for (let offset = 0; offset < file.size;) {
        if (cancelled(index)) throw CANCELLED;
        const end = Math.min(file.size, offset + chunkSize);
        const bytes = new Uint8Array(await file.slice(offset, end).arrayBuffer());
        if (bytes.length !== end - offset) throw new Error("The file could not be read.");
        const answer = object(await call("chat.upload.chunk", { token, offset, data: base64(bytes) }));
        if (answer.offset !== end) throw new Error("The upload could not be completed.");
        offset = end;
      }
      if (cancelled(index)) throw CANCELLED;
      const [path, extra] = uploadedPaths(await call("chat.upload.finish", { token }));
      if (!path || extra) throw new Error("The upload could not be completed.");
      paths.push(path);
    } catch (error) {
      // Straight to the host, not behind another step deadline.
      void host("chat.upload.cancel", { token }).catch(() => undefined);
      if (error === CANCELLED) {
        paths.push("");
        continue;
      }
      return { error: error instanceof Error ? error.message : String(error) };
    }
  }
  return { paths };
}

/// An older host's one-frame upload (24 MiB at most): it cannot stop once sent, so a file cancelled
/// before it goes is left out, and one cancelled while it goes gets no path (its copy stays unused).
async function legacyUpload(
  files: File[],
  call: Call,
  cancelled: (index: number) => boolean = () => false,
): Promise<UploadResult> {
  try {
    const sending = files.flatMap((file, index) => (cancelled(index) ? [] : [{ file, index }]));
    if (!sending.length) return { paths: files.map(() => "") };
    const payload = await Promise.all(
      sending.map(async ({ file }) => ({ name: file.name, data: base64(new Uint8Array(await file.arrayBuffer())) })),
    );
    const sent = uploadedPaths(await call("chat.upload", { files: payload }));
    if (sent.length !== sending.length) return undefined;
    const paths = files.map(() => "");
    sending.forEach(({ index }, at) => {
      if (!cancelled(index)) paths[index] = sent[at]!;
    });
    return { paths };
  } catch (error) {
    if (notTaken(error)) return undefined;
    return { error: error instanceof Error ? error.message : String(error) };
  }
}
