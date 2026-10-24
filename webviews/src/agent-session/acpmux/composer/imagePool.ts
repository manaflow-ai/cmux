// Runs an attached image's pixel work (imageWork.ts) in one worker beside the page, so pasting
// several Retina screenshots never blocks typing (Leo, 2026-10-24: "they freeze the composer").
// The bundled page starts `image-worker.js` from its own origin, as the code highlighter does
// (conversation/highlightPool.ts); the Vite dev server serves the module itself. Where no worker
// starts, or one stops answering, the work runs on the page as before.
import { usesHighlightWorker } from "../conversation/highlightPool";
import { prepareImage, thumbnailOf, type PreparedImage, type Thumb } from "./imageWork";

/// The worker's file, beside the bundled page.
export const IMAGE_WORKER_FILE = "image-worker.js";
/// A job the worker has not answered in this long is done on the page instead.
export const IMAGE_JOB_DEADLINE_MS = 20_000;

export type ImageJob =
  | { id: number; kind: "prepare"; file: Blob }
  | { id: number; kind: "thumb"; image: { mimeType: string; data: string } };
/// `unsupported`: the worker cannot draw (no OffscreenCanvas there); the page does the job.
export type ImageJobResult = { id: number; value: PreparedImage | Thumb | undefined; unsupported?: boolean };
type Job = ImageJob extends infer J ? (J extends ImageJob ? Omit<J, "id"> : never) : never;

let worker: Worker | null | undefined;
let nextId = 1;
const waiting = new Map<number, (value: PreparedImage | Thumb | undefined, failed?: boolean) => void>();

function startWorker(): Worker | null {
  if (worker !== undefined) return worker;
  worker = null;
  if (typeof Worker === "undefined" || typeof location === "undefined") return null;
  // The bundled page ships the worker beside it; the Vite dev server (import.meta.hot) serves the
  // module. Anywhere else (a unit test's DOM) the work runs here, in the engine the test gave it.
  const bundled = usesHighlightWorker(location.protocol);
  if (!bundled && !import.meta.hot) return null;
  try {
    const started = bundled
      ? new Worker(new URL(IMAGE_WORKER_FILE, location.href), { type: "module" })
      : new Worker(new URL("./imageWorker.ts", import.meta.url), { type: "module" });
    started.onmessage = ({ data }: MessageEvent<ImageJobResult>) => {
      if (data.unsupported) return stopWorker();
      const settle = waiting.get(data.id);
      waiting.delete(data.id);
      settle?.(data.value);
    };
    // A worker that could not start (or crashed): every job it held, and every later one, runs here.
    started.onerror = () => stopWorker();
    worker = started;
  } catch {
    worker = null;
  }
  return worker;
}

function stopWorker() {
  worker?.terminate();
  worker = null;
  const settles = [...waiting.values()];
  waiting.clear();
  for (const settle of settles) settle(undefined, true);
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
      // A worker that answers nothing is wedged: the page takes over from here.
      if (waiting.has(id)) stopWorker();
    }, IMAGE_JOB_DEADLINE_MS);
    waiting.set(id, (value, failed) => {
      clearTimeout(deadline);
      resolve(failed ? here(job) : value);
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
