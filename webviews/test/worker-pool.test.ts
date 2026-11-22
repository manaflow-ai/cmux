import { expect, test } from "bun:test";
import {
  createDiffWorkerPoolOptions,
  createDiffWorkerPoolStats,
  diffWorkerModuleURL,
  diffWorkerPoolSizeForUserAgent,
} from "../src/worker-pool";

test("diff worker pool uses the desktop cap by default", () => {
  expect(diffWorkerPoolSizeForUserAgent("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)")).toBe(3);
  expect(diffWorkerPoolSizeForUserAgent(undefined)).toBe(3);
});

test("diff worker pool uses the mobile cap for phone and tablet user agents", () => {
  expect(diffWorkerPoolSizeForUserAgent("Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X)")).toBe(1);
  expect(diffWorkerPoolSizeForUserAgent("Mozilla/5.0 (iPad; CPU OS 18_5 like Mac OS X)")).toBe(1);
  expect(diffWorkerPoolSizeForUserAgent("Mozilla/5.0 (Linux; Android 15; Pixel 9) Mobile")).toBe(1);
});

test("the worker entry URL is the emitted sibling chunk of the diff surface", () => {
  expect(diffWorkerModuleURL.href.endsWith("/diff-worker.mjs")).toBe(true);
});

class FakeWorker {
  static created: { url: string; type: string | undefined }[] = [];
  private listeners = new Map<string, Array<() => void>>();

  constructor(url: URL, options?: { type?: string }) {
    FakeWorker.created.push({ url: url.href, type: options?.type });
  }

  addEventListener(type: string, listener: () => void): void {
    this.listeners.set(type, [...(this.listeners.get(type) ?? []), listener]);
  }

  emit(type: string): void {
    for (const listener of this.listeners.get(type) ?? []) listener();
  }
}

test("the worker factory spawns module workers from the entry and counts traffic", () => {
  FakeWorker.created = [];
  const workerURL = new URL("cmux-diff-viewer://token/assets/app/chunks/diff-worker.mjs");
  const stats = createDiffWorkerPoolStats(workerURL);
  const target = { dataset: {} as DOMStringMap };
  const options = createDiffWorkerPoolOptions(workerURL, stats, FakeWorker as unknown as typeof Worker, target);
  expect(stats).toEqual({ workerURL: workerURL.href, created: 0, messages: 0, errors: 0 });

  const first = options.workerFactory!() as unknown as FakeWorker;
  const second = options.workerFactory!() as unknown as FakeWorker;
  expect(FakeWorker.created).toEqual([
    { url: workerURL.href, type: "module" },
    { url: workerURL.href, type: "module" },
  ]);
  expect(stats.created).toBe(2);

  first.emit("message");
  second.emit("message");
  second.emit("message");
  first.emit("error");
  expect(stats.messages).toBe(3);
  expect(stats.errors).toBe(1);
  // Mirrored onto the document element so a debug-socket eval in an isolated
  // world can read the counters without access to page globals.
  expect(target.dataset).toEqual({
    cmuxDiffWorkerUrl: workerURL.href,
    cmuxDiffWorkersCreated: "2",
    cmuxDiffWorkerMessages: "3",
    cmuxDiffWorkerErrors: "1",
  });
});
