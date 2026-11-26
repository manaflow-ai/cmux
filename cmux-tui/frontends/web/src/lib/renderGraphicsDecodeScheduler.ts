import type { RenderGraphicImage } from "cmux/raw";
import {
  decodeRenderGraphicImage,
  renderGraphicDecodedByteLength,
} from "./renderGraphics";
import type {
  RenderGraphicsDecodeRequest,
  RenderGraphicsDecodeResponse,
  RenderGraphicsDecodeResult,
} from "../workers/renderGraphicsDecoder";

export const RENDER_GRAPHICS_DECODE_WORKER_CAP = 2;
const RENDER_GRAPHICS_DECODE_OWNER_CAP = 512;
const RENDER_GRAPHIC_MAIN_THREAD_FALLBACK_MAX_DECODED_BYTES = 256 * 1024;
const RENDER_GRAPHICS_DECODE_WORKER_MAX_FAILURES = 3;

interface DecodeJob {
  canceled: boolean;
  complete(results: RenderGraphicsDecodeResult[]): void;
  images: RenderGraphicImage[];
  owner: symbol;
  requestId: number;
  workerFailures: number;
}

interface DecodeWorkerSlot {
  job: DecodeJob | null;
  worker: Worker;
}

interface FallbackDecodeResult {
  deferred: RenderGraphicImage[];
  results: RenderGraphicsDecodeResult[];
}

function decodeWithoutWorker(
  images: readonly RenderGraphicImage[],
): FallbackDecodeResult {
  let remainingDecodedBytes =
    RENDER_GRAPHIC_MAIN_THREAD_FALLBACK_MAX_DECODED_BYTES;
  const deferred: RenderGraphicImage[] = [];
  const results: RenderGraphicsDecodeResult[] = [];
  for (const image of images) {
    // A failed or unavailable worker must not turn a multi-megabyte validation
    // scan and decode into one long task on the browser thread.
    const byteLength = renderGraphicDecodedByteLength(image);
    if (byteLength !== null && byteLength > remainingDecodedBytes) {
      deferred.push(image);
      continue;
    }
    if (byteLength !== null) remainingDecodedBytes -= byteLength;
    const decoded = decodeRenderGraphicImage(image);
    results.push({
      id: image.id,
      generation: image.generation,
      pixels: decoded?.pixels.buffer ?? null,
    });
  }
  return { deferred, results };
}

function canDecodeWithoutWorker(image: RenderGraphicImage): boolean {
  const byteLength = renderGraphicDecodedByteLength(image);
  return byteLength !== null
    && byteLength <= RENDER_GRAPHIC_MAIN_THREAD_FALLBACK_MAX_DECODED_BYTES;
}

/**
 * Owns a fixed decoder-worker pool for one application root.
 *
 * Jobs are latest-wins per RenderGraphics owner. Superseded in-flight work may
 * finish inside a worker, but its result is discarded and no second job for
 * that owner starts until the first leaves the worker.
 */
export class RenderGraphicsDecodeScheduler {
  private readonly activeOwners = new Set<symbol>();
  private readonly jobsByOwner = new Map<symbol, DecodeJob>();
  private readonly queue: DecodeJob[] = [];
  private readonly slots: DecodeWorkerSlot[] = [];
  private creationStopped = false;
  private disposalToken: symbol | null = null;
  private disposed = false;
  private fallbackJob: DecodeJob | null = null;
  private fallbackTimer: ReturnType<typeof setTimeout> | null = null;
  private nextRequestId = 0;

  schedule(
    owner: symbol,
    images: readonly RenderGraphicImage[],
    complete: (results: RenderGraphicsDecodeResult[]) => void,
  ): () => void {
    this.cancel(owner);
    if (this.disposed) return () => {};
    const requestId = this.nextRequestId === Number.MAX_SAFE_INTEGER
      ? 1
      : this.nextRequestId + 1;
    this.nextRequestId = requestId;
    const job: DecodeJob = {
      canceled: false,
      complete,
      images: [...images],
      owner,
      requestId,
      workerFailures: 0,
    };
    if (this.jobsByOwner.size >= RENDER_GRAPHICS_DECODE_OWNER_CAP) {
      job.canceled = true;
      return () => {
        job.canceled = true;
      };
    }
    this.jobsByOwner.set(owner, job);
    this.queue.push(job);
    this.pump();
    return () => this.cancelJob(job);
  }

  retain(): void {
    this.disposalToken = null;
  }

  scheduleDispose(): void {
    const token = Symbol("render-graphics-decoder-disposal");
    this.disposalToken = token;
    queueMicrotask(() => {
      if (this.disposalToken !== token) return;
      this.disposalToken = null;
      this.dispose();
    });
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    if (this.fallbackTimer !== null) clearTimeout(this.fallbackTimer);
    this.fallbackTimer = null;
    if (this.fallbackJob !== null) this.fallbackJob.canceled = true;
    this.fallbackJob = null;
    for (const job of this.jobsByOwner.values()) job.canceled = true;
    this.jobsByOwner.clear();
    this.queue.length = 0;
    this.activeOwners.clear();
    for (const slot of this.slots) slot.worker.terminate();
    this.slots.length = 0;
  }

  private cancel(owner: symbol): void {
    const job = this.jobsByOwner.get(owner);
    if (job !== undefined) this.cancelJob(job);
  }

  private cancelJob(job: DecodeJob): void {
    if (job.canceled) return;
    job.canceled = true;
    if (this.jobsByOwner.get(job.owner) === job) this.jobsByOwner.delete(job.owner);
    const queued = this.queue.indexOf(job);
    if (queued >= 0) this.queue.splice(queued, 1);
  }

  private pump(): void {
    if (this.disposed) return;
    while (true) {
      const job = this.takeRunnableJob();
      if (job === null) return;
      let slot = this.slots.find((candidate) => candidate.job === null);
      if (slot === undefined && !this.creationStopped
        && this.slots.length < RENDER_GRAPHICS_DECODE_WORKER_CAP) {
        slot = this.createSlot();
        if (slot === undefined) job.workerFailures += 1;
      }
      if (slot === undefined) {
        this.queue.unshift(job);
        if (this.slots.length === 0 && this.creationStopped) this.startFallback();
        return;
      }
      this.startWorkerJob(slot, job);
    }
  }

  private takeRunnableJob(): DecodeJob | null {
    for (let index = 0; index < this.queue.length;) {
      const job = this.queue[index]!;
      if (job.canceled || this.jobsByOwner.get(job.owner) !== job) {
        this.queue.splice(index, 1);
        continue;
      }
      if (this.activeOwners.has(job.owner)) {
        index += 1;
        continue;
      }
      this.queue.splice(index, 1);
      return job;
    }
    return null;
  }

  private createSlot(): DecodeWorkerSlot | undefined {
    if (this.creationStopped || typeof Worker === "undefined") {
      this.creationStopped = true;
      return undefined;
    }
    try {
      const worker = new Worker(
        new URL("../workers/renderGraphicsDecoder.ts", import.meta.url),
        { type: "module" },
      );
      const slot: DecodeWorkerSlot = { job: null, worker };
      worker.onmessage = (event: MessageEvent<RenderGraphicsDecodeResponse>) => {
        this.finishWorkerJob(slot, event.data);
      };
      worker.onerror = () => this.failWorker(slot);
      worker.onmessageerror = () => this.failWorker(slot);
      this.slots.push(slot);
      return slot;
    } catch {
      this.creationStopped = true;
      return undefined;
    }
  }

  private startWorkerJob(slot: DecodeWorkerSlot, job: DecodeJob): void {
    slot.job = job;
    this.activeOwners.add(job.owner);
    const request: RenderGraphicsDecodeRequest = {
      requestId: job.requestId,
      images: job.images,
    };
    try {
      slot.worker.postMessage(request);
    } catch {
      this.failWorker(slot);
    }
  }

  private finishWorkerJob(
    slot: DecodeWorkerSlot,
    response: RenderGraphicsDecodeResponse,
  ): void {
    const job = slot.job;
    if (job === null) return;
    if (response.requestId !== job.requestId) {
      this.failWorker(slot);
      return;
    }
    slot.job = null;
    this.activeOwners.delete(job.owner);
    this.finishJob(job, response.results);
    this.pump();
  }

  private failWorker(slot: DecodeWorkerSlot): void {
    const index = this.slots.indexOf(slot);
    if (index < 0) return;
    this.slots.splice(index, 1);
    slot.worker.terminate();
    this.creationStopped = true;
    const job = slot.job;
    slot.job = null;
    if (job !== null) {
      job.workerFailures += 1;
      this.activeOwners.delete(job.owner);
      if (!job.canceled && this.jobsByOwner.get(job.owner) === job) {
        this.queue.unshift(job);
      }
    }
    this.pump();
  }

  private startFallback(): void {
    if (this.disposed || this.fallbackTimer !== null || this.fallbackJob !== null) return;
    const job = this.takeRunnableJob();
    if (job === null) return;
    this.fallbackJob = job;
    this.activeOwners.add(job.owner);
    this.fallbackTimer = setTimeout(() => {
      this.fallbackTimer = null;
      this.fallbackJob = null;
      this.activeOwners.delete(job.owner);
      if (job.canceled || this.disposed || this.jobsByOwner.get(job.owner) !== job) {
        this.pump();
        return;
      }
      const { deferred, results } = decodeWithoutWorker(job.images);
      job.images = deferred;
      if (deferred.length === 0) {
        this.finishJob(job, results);
        this.pump();
        return;
      }
      this.publishJobResults(job, results);
      if (job.canceled || this.disposed || this.jobsByOwner.get(job.owner) !== job) {
        this.pump();
        return;
      }
      if (deferred.some(canDecodeWithoutWorker)) {
        this.queue.unshift(job);
        this.pump();
        return;
      }
      if (job.workerFailures < RENDER_GRAPHICS_DECODE_WORKER_MAX_FAILURES) {
        this.creationStopped = false;
        this.queue.unshift(job);
        this.pump();
        return;
      }
      // Leave the deferred image uncached so a later owner lifecycle can
      // retry, but retire this exhausted job and unblock unrelated owners.
      this.finishJob(job, []);
      this.pump();
    }, 0);
  }

  private publishJobResults(
    job: DecodeJob,
    results: RenderGraphicsDecodeResult[],
  ): void {
    if (results.length === 0 || job.canceled || this.disposed
      || this.jobsByOwner.get(job.owner) !== job) return;
    job.complete(results);
  }

  private finishJob(job: DecodeJob, results: RenderGraphicsDecodeResult[]): void {
    if (job.canceled || this.disposed || this.jobsByOwner.get(job.owner) !== job) return;
    this.jobsByOwner.delete(job.owner);
    job.complete(results);
  }
}
