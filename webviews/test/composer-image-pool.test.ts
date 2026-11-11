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
/// Each decode the page itself does: a Retina screenshot decoded here stalls typing.
let decodedOnPage = 0;
afterEach(() => {
  g.Worker = saved.Worker;
  g.location = saved.location;
  delete g.createImageBitmap;
  delete g.OffscreenCanvas;
  made.length = 0;
  decodedOnPage = 0;
});

/// A fresh copy of the pool on the bundled page, with FakeWorker as its Worker.
async function pool() {
  g.Worker = FakeWorker;
  g.createImageBitmap = async () => {
    decodedOnPage += 1;
    throw new Error("not a picture");
  };
  g.OffscreenCanvas = class {};
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
  expect(await result).toBeUndefined();
  expect(decodedOnPage).toBe(1);
  expect(made[0]!.terminated).toBe(true);
  await prepareImageOffThread(new Blob(["png"]));
  expect(made).toHaveLength(1);
});

test("a worker that stops answering fails its job, never reruns it on the page, and is replaced", async () => {
  const { prepareImageOffThread, imageJobDeadline } = await pool();
  imageJobDeadline.ms = 20;
  const wedged = prepareImageOffThread(new Blob(["a"]));
  expect(await wedged).toBeUndefined();
  expect(decodedOnPage).toBe(0);
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
  expect(decodedOnPage).toBe(0);
});

test("a worker whose script fails fails its job and never decodes it on the page", async () => {
  const { prepareImageOffThread } = await pool();
  const job = prepareImageOffThread(new Blob(["a"]));
  made[0]!.onerror?.();
  expect(await job).toBeUndefined();
  expect(decodedOnPage).toBe(0);
  // The next job tries a new worker.
  void prepareImageOffThread(new Blob(["b"]));
  expect(made).toHaveLength(2);
});

test("the same file made again takes the preview made before; another file of its name and size does not", async () => {
  const { prepareImageOffThread } = await pool();
  const shot = (byte: number) =>
    new File([new Uint8Array(128).fill(byte)], "Screenshot.png", {
      type: "image/png",
      lastModified: 1_794_380_000_000,
    });
  /// The file's identity is a few small reads: its job goes once they answer.
  const posted = async (count: number) => {
    for (let turn = 0; turn < 100 && (made[0]?.posted.length ?? 0) < count; turn += 1)
      await new Promise((resolve) => setImmediate(resolve));
    expect(made[0]?.posted.length ?? 0).toBe(count);
  };
  const first = prepareImageOffThread(shot(1));
  await posted(1);
  const worker = made[0]!;
  worker.answer({ id: worker.posted[0]!.id, value: { mimeType: "image/png", data: "AAAA" } });
  expect(await first).toEqual({ mimeType: "image/png", data: "AAAA" });
  expect(await prepareImageOffThread(shot(1))).toEqual({ mimeType: "image/png", data: "AAAA" });
  expect(worker.posted).toHaveLength(1);
  const other = prepareImageOffThread(shot(2));
  await posted(2);
  worker.answer({ id: worker.posted[1]!.id, value: { mimeType: "image/png", data: "BBBB" } });
  expect(await other).toEqual({ mimeType: "image/png", data: "BBBB" });
});
