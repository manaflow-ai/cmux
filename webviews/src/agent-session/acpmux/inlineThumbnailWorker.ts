import { thumbnail, type ThumbnailResult } from "./attachments";

/// The same-origin worker emitted beside pane.js by build-agent-pane-web.sh. Dev and test hosts
/// without the emitted worker fall back to attachments.ts' bounded main-thread decoder.
const WORKER_FILE = "inline-thumbnail-worker.js";
type WorkerResponse = { id: number; result?: ThumbnailResult };
type Pending = { resolve: (result: ThumbnailResult | undefined) => void };

let worker: Worker | undefined;
let nextID = 1;
const pending = new Map<number, Pending>();

function workerForPage(): Worker | undefined {
  if (typeof Worker === "undefined" || typeof location === "undefined") return undefined;
  if (location.protocol !== "cmux-agent:" && location.protocol !== "cmux-page:") return undefined;
  if (worker) return worker;
  try {
    worker = new Worker(new URL(WORKER_FILE, location.href), { type: "module" });
    worker.addEventListener("message", (event: MessageEvent<WorkerResponse>) => {
      const request = pending.get(event.data.id);
      if (!request) return;
      pending.delete(event.data.id);
      request.resolve(event.data.result);
    });
    worker.addEventListener("error", () => {
      const failed = [...pending.values()];
      pending.clear();
      worker?.terminate();
      worker = undefined;
      for (const request of failed) request.resolve(undefined);
    });
    return worker;
  } catch {
    worker = undefined;
    return undefined;
  }
}

/// Decodes and downsamples one preview away from the editor's main thread. The worker returns a
/// bounded data URL so the page never owns an object URL that needs lifecycle cleanup.
export function thumbnailOffMain(
  image: { mimeType: string; data: string },
  height = 160,
): Promise<ThumbnailResult | undefined> {
  const current = workerForPage();
  if (!current) return thumbnail(image, height);
  const id = nextID++;
  return new Promise((resolve) => {
    pending.set(id, { resolve });
    try {
      current.postMessage({ id, mimeType: image.mimeType, data: image.data, height });
    } catch {
      pending.delete(id);
      resolve(undefined);
    }
  });
}
