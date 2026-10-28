// Runs an attached image's pixel work (imageWork.ts) in one worker beside the page, so pasting
// several Retina screenshots never blocks typing (Leo, 2026-10-24: "they freeze the composer").
// The bundled page starts `image-worker.js` from its own origin, as the code highlighter does
// (conversation/highlightPool.ts); the Vite dev server serves the module itself. Where there is no
// Worker, or the engine cannot draw in one, the work runs on the page as before; a worker that fails
// or stops answering fails its jobs (the file then goes as a file) and is replaced, never handing
// them to the page.
import { prepareImage, thumbnailOf, type PreparedImage, type Thumb } from "./imageWork";

/// The worker's file, beside the bundled page.
export const IMAGE_WORKER_FILE = "image-worker.js";
/// A job the worker has not answered in this long fails, and the worker is replaced (a test may
/// shorten it).
export const imageJobDeadline = { ms: 20_000 };

export type ImageJob =
  | { id: number; kind: "prepare"; file: Blob }
  | { id: number; kind: "thumb"; image: { mimeType: string; data: string } };
/// `unsupported`: the worker cannot draw (no OffscreenCanvas there); the page does the job.
export type ImageJobResult = { id: number; value: PreparedImage | Thumb | undefined; unsupported?: boolean };
type Job = ImageJob extends infer J ? (J extends ImageJob ? Omit<J, "id"> : never) : never;

/// The worker; null where none can serve this page (the page does the work, as before workers).
let worker: Worker | null | undefined;
let nextId = 1;
/// Each job the worker holds, with the worker it went to: a late event of a worker already
/// replaced never touches its successor's jobs.
const waiting = new Map<
  number,
  { worker: Worker; settle(value: PreparedImage | Thumb | undefined, onPage?: boolean): void }
>();

function startWorker(): Worker | null {
  if (worker !== undefined) return worker;
  worker = null;
  if (typeof Worker === "undefined" || typeof location === "undefined") return null;
  // The bundled page ships the worker beside it; the Vite dev server (import.meta.hot) serves the
  // module. Anywhere else (a unit test's DOM) the work runs here, in the engine the test gave it.
  // The bundled page's schemes, as conversation/highlightPool.ts usesHighlightWorker (not imported:
  // it loads the diff renderer's web components into every importer of attachments.ts).
  const bundled = location.protocol === "cmux-agent:" || location.protocol === "cmux-page:";
  if (!bundled && !import.meta.hot) return null;
  try {
    const started = bundled
      ? new Worker(new URL(IMAGE_WORKER_FILE, location.href), { type: "module" })
      : new Worker(new URL("./imageWorker.ts", import.meta.url), { type: "module" });
    started.onmessage = ({ data }: MessageEvent<ImageJobResult>) => {
      if (data.unsupported) return stopWorker(started, "page");
      const job = waiting.get(data.id);
      if (job?.worker !== started) return;
      waiting.delete(data.id);
      job.settle(data.value);
    };
    // A worker that failed (its script did not load, or it crashed): its jobs fail, never rerun on
    // the page, and the next job starts a new one. Only a worker that says it cannot draw hands
    // work to the page.
    started.onerror = () => stopWorker(started, "fresh");
    worker = started;
  } catch {
    worker = null;
  }
  return worker;
}

/// Ends `stopped` if it is still the worker. `page`: the engine cannot draw in a worker, its jobs
/// run here. `fresh`: it failed or stopped answering; its jobs fail (never rerun on the page, where a Retina
/// screenshot would stall typing) and the next job starts a new worker.
function stopWorker(stopped: Worker, then: "page" | "fresh") {
  stopped.terminate();
  if (worker === stopped) worker = then === "page" ? null : undefined;
  for (const [id, job] of waiting) {
    if (job.worker !== stopped) continue;
    waiting.delete(id);
    job.settle(undefined, then === "page");
  }
}

function here(job: Job): Promise<PreparedImage | Thumb | undefined> {
  return job.kind === "prepare" ? prepareImage(job.file) : thumbnailOf(job.image);
}

function run(job: Job): Promise<PreparedImage | Thumb | undefined> {
  const started = startWorker();
  if (!started) return here(job);
  const id = nextId++;
  return new Promise((resolve) => {
    const deadline = setTimeout(() => {
      if (waiting.has(id)) stopWorker(started, "fresh");
    }, imageJobDeadline.ms);
    waiting.set(id, {
      worker: started,
      settle: (value, onPage) => {
        clearTimeout(deadline);
        resolve(onPage ? here(job) : value);
      },
    });
    started.postMessage({ ...job, id });
  });
}

/// An image's metadata-free preview and its thumbnail, made off the main thread.
export function prepareImageOffThread(file: Blob): Promise<PreparedImage | undefined> {
  return run({ kind: "prepare", file }) as Promise<PreparedImage | undefined>;
}

/// The thumbnail of a staged image's bytes, made off the main thread.
export function thumbnailOffThread(image: { mimeType: string; data: string }): Promise<Thumb | undefined> {
  return run({ kind: "thumb", image }) as Promise<Thumb | undefined>;
}

/// Thumbnails made with their image's preview, by the chip's id, so its chip draws one at once
/// instead of decoding the image again. The newest few are kept.
const thumbs = new Map<string, Thumb>();
const KEPT_THUMBS = 64;

export function keepThumb(id: string, thumb: Thumb) {
  thumbs.delete(id);
  thumbs.set(id, thumb);
  if (thumbs.size > KEPT_THUMBS) thumbs.delete(thumbs.keys().next().value!);
}

export function keptThumb(id: string): Thumb | undefined {
  return thumbs.get(id);
}
