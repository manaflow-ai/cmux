// The image worker's lifecycle (composer/imagePool.ts): a job goes to the worker beside the bundled
// page; a worker that cannot draw hands its jobs to the page; a late event from a worker already
// replaced never ends its successor.
import { afterEach, expect, test } from "bun:test";

type Posted = { id: number; kind: string };
const made: FakeWorker[] = [];
class FakeWorker {
  onmessage: ((event: { data: unknown }) => void) | null = null;
  onerror: (() => void) | null = null;
  posted: Posted[] = [];
  terminated = false;
  constructor(public url: URL) {
    made.push(this);
  }
  postMessage(job: Posted) {
    this.posted.push(job);
  }
  terminate() {
    this.terminated = true;
  }
  answer(data: unknown) {
    this.onmessage?.({ data });
  }
}

const g = globalThis as Record<string, unknown>;
const saved = { Worker: g.Worker, location: g.location };
afterEach(() => {
  g.Worker = saved.Worker;
  g.location = saved.location;
  made.length = 0;
});

/// A fresh copy of the pool on the bundled page, with FakeWorker as its Worker.
async function pool() {
  g.Worker = FakeWorker;
  g.location = { protocol: "cmux-agent:", href: "cmux-agent://pane/index.html" };
  return import(`../src/agent-session/acpmux/composer/imagePool.ts?${Math.random()}`);
}

test("the bundled page sends the job to image-worker.js beside it and takes its answer", async () => {
  const { prepareImageOffThread } = await pool();
  const result = prepareImageOffThread(new Blob(["png"]));
  const worker = made[0]!;
  expect(worker.url.href).toBe("cmux-agent://pane/image-worker.js");
  worker.answer({ id: worker.posted[0]!.id, value: { mimeType: "image/png", data: "AAAA" } });
  expect(await result).toEqual({ mimeType: "image/png", data: "AAAA" });
});

test("a worker that cannot draw hands its job to the page, and no worker starts again", async () => {
  const { prepareImageOffThread } = await pool();
  const result = prepareImageOffThread(new Blob(["png"]));
  made[0]!.answer({ id: made[0]!.posted[0]!.id, value: undefined, unsupported: true });
  // No engine here either: the page answers that it cannot decode it.
  expect(await result).toBeUndefined();
  expect(made[0]!.terminated).toBe(true);
  await prepareImageOffThread(new Blob(["png"]));
  expect(made).toHaveLength(1);
});

test("a worker that stops answering fails its job, never reruns it on the page, and is replaced", async () => {
  const { prepareImageOffThread, imageJobDeadline } = await pool();
  imageJobDeadline.ms = 20;
  const wedged = prepareImageOffThread(new Blob(["a"]));
  expect(await wedged).toBeUndefined();
  const old = made[0]!;
  expect(old.terminated).toBe(true);
  // The next job goes to a new worker; the old one's late error or answer never touches it.
  const next = prepareImageOffThread(new Blob(["b"]));
  const fresh = made[1]!;
  expect(fresh).toBeDefined();
  old.onerror?.();
  old.answer({ id: fresh.posted[0]!.id, value: { mimeType: "image/png", data: "OLD" } });
  expect(fresh.terminated).toBe(false);
  fresh.answer({ id: fresh.posted[0]!.id, value: { mimeType: "image/png", data: "NEW" } });
  expect(await next).toEqual({ mimeType: "image/png", data: "NEW" });
});
