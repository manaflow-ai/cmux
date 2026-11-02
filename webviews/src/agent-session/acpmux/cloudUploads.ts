// Session uploads use native staging: one bounded base64 chunk crosses the page bridge at a
// time. The native host binds the token to the session/gesture and enforces its storage quota.
// Older hosts keep the legacy upload call; only a missing staging method selects that path.
import { base64 } from "./attachments";
import { translate } from "./i18n";

/// Cancellation checks between chunks and notifications while the native finish is in flight.
export type UploadCancelled = ((index: number) => boolean) & {
  subscribe?(index: number, changed: () => void): () => void;
};

/// `final`: the host refused the file outright (the app could not save it), so trying again would
/// fail the same way; any other error (a link down, a timeout) may pass on the next try.
export type UploadResult = { paths: string[] } | { error: string; final?: boolean } | undefined;
/// How much of file `index` of an upload reached the host, 0 to 1 (its tile's progress ring).
export type UploadProgressReport = (index: number, done: number) => void;
type Call = (method: string, params: Record<string, unknown>) => Promise<unknown>;
const NOT_TAKEN = new Set(["unsupported", "native.invalid_request"]);
/// Host error codes that fail the same way every time: the app could not save the file.
const REFUSED = new Set(["io", ...NOT_TAKEN]);
const CHUNK_BYTES = 512 * 1024;
const LEGACY_FRAME_SAFE_BYTES = 24 * 1024 * 1024;

/// How long one staging step (begin or one chunk) may wait for the host. The native finish keeps its
/// own bounded idle/per-chunk deadline while streaming, so elapsed transfer time has no page cap.
export const UPLOAD_STEP_DEADLINE_MS = 30_000;
export const UPLOAD_TIMED_OUT = "The upload timed out: the app did not answer.";

/// `call`, refused when the host does not answer within `ms`; null delegates its deadline to native.
export function callWithin(call: Call, ms: number | null = UPLOAD_STEP_DEADLINE_MS, signal?: AbortSignal): Call {
  return (method, params) =>
    new Promise((resolve, reject) => {
      let late = false;
      const stop = () => {
        if (timer !== undefined) clearTimeout(timer);
        signal?.removeEventListener("abort", abort);
      };
      const abort = () => {
        late = true;
        stop();
        reject(CANCELLED);
      };
      const timer =
        ms === null
          ? undefined
          : setTimeout(() => {
              late = true;
              stop();
              reject(new Error(UPLOAD_TIMED_OUT));
            }, ms);
      signal?.addEventListener("abort", abort, { once: true });
      if (signal?.aborted) {
        abort();
        return;
      }
      Promise.resolve()
        .then(() => call(method, params))
        .then(
          (value) => {
            stop();
            // An upload the host started after the page gave up on it: the host drops its stage.
            const token = (value as { token?: unknown } | null)?.token;
            if (late && method === "chat.upload.begin" && typeof token === "string")
              void call("chat.upload.cancel", { token }).catch(() => undefined);
            resolve(value);
          },
          (error: unknown) => {
            stop();
            reject(error);
          },
        );
    });
}

/// `blob` as base64. The browser encodes it off the main thread (FileReader's data: URL): a 512 KiB
/// chunk encoded here took a few ms of the main thread per chunk, between the person's keys, all
/// through a 2 GB upload (agent-pane-attach-huge-files' typing p95 on the CI runner). Where there is
/// no FileReader (a test host) it is encoded here.
async function blobBase64(blob: Blob): Promise<string> {
  if (typeof FileReader === "undefined") return base64(new Uint8Array(await blob.arrayBuffer()));
  const url = await new Promise<string>((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result));
    reader.onerror = () => reject(reader.error ?? new Error(translate("upload.notRead")));
    reader.readAsDataURL(blob);
  });
  const data = url.slice(url.indexOf(",") + 1);
  if (blob.size > 0 && !data) throw new Error(translate("upload.notRead"));
  return data;
}

/// Thrown inside an upload the person cancelled; never a note.
const CANCELLED = new Error("cancelled");

function notTaken(error: unknown): boolean {
  return NOT_TAKEN.has((error as { code?: string } | null)?.code ?? "");
}

/// The answer for a failed upload: its words, and whether the host refused it outright.
function uploadError(error: unknown): UploadResult {
  const text = error instanceof Error ? error.message : String(error);
  return REFUSED.has((error as { code?: string } | null)?.code ?? "") ? { error: text, final: true } : { error: text };
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
  cancelled: UploadCancelled = () => false,
  progress?: UploadProgressReport,
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
          return { error: translate("upload.hostTooLarge") };
        return legacyUpload(files, call, cancelled);
      }
      return uploadError(error);
    }
    begun = true;
    const begin = object(started);
    if (index === 0 && typeof begin.batchToken === "string" && begin.batchToken) batchToken = begin.batchToken;
    const token = begin.token;
    if (typeof token !== "string" || !token) return { error: translate("upload.notStarted") };
    const controller = new AbortController();
    const unsubscribe = cancelled.subscribe?.(index, () => {
      if (cancelled(index)) controller.abort();
    });
    const step = callWithin(host, UPLOAD_STEP_DEADLINE_MS, controller.signal);
    const finishCall = callWithin(host, null, controller.signal);
    try {
      if (begin.size !== file.size || !Number.isSafeInteger(begin.chunkSize) || Number(begin.chunkSize) <= 0)
        throw new Error(translate("upload.notStarted"));
      const chunkSize = Math.min(Number(begin.chunkSize), CHUNK_BYTES);
      for (let offset = 0; offset < file.size;) {
        if (cancelled(index)) throw CANCELLED;
        const end = Math.min(file.size, offset + chunkSize);
        const slice = file.slice(offset, end);
        if (slice.size !== end - offset) throw new Error(translate("upload.notRead"));
        const answer = object(await step("chat.upload.chunk", { token, offset, data: await blobBase64(slice) }));
        if (answer.offset !== end) throw new Error(translate("upload.notCompleted"));
        offset = end;
        progress?.(index, end / file.size);
      }
      if (cancelled(index)) throw CANCELLED;
      const [path, extra] = uploadedPaths(await finishCall("chat.upload.finish", { token }));
      if (!path || extra) throw new Error(translate("upload.notCompleted"));
      if (cancelled(index)) throw CANCELLED;
      paths.push(path);
    } catch (error) {
      // Keep cancellation owned until the host has stopped reading and removed its stage.
      await call("chat.upload.cancel", { token }).catch(() => undefined);
      if (error === CANCELLED) {
        paths.push("");
        continue;
      }
      return uploadError(error);
    } finally {
      unsubscribe?.();
    }
  }
  return { paths };
}

/// An older host's one-frame upload (24 MiB at most): it cannot stop once sent, so a file cancelled
/// before it goes is left out, and one cancelled while it goes gets no path (its copy stays unused).
async function legacyUpload(
  files: File[],
  call: Call,
  cancelled: UploadCancelled = () => false,
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
