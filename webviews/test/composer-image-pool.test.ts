// The image worker's lifecycle (composer/imagePool.ts): a job goes to the worker beside the bundled
// page; a worker that cannot draw hands its jobs to the page; a late event from a worker already
// replaced never ends its successor.
import { afterEach, expect, test } from "bun:test";

type Posted = { id: number; kind: string; file?: Blob };
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

test("a disk link starts one thumbnail-only job on display and keeps its File out of the draft", async () => {
  const { localImagePreview, previewForFile } = await pool();
  const file = new File(["pixels"], "photo.png", { type: "image/png" });
  const chip = { path: "/tmp/photo.png", [localImagePreview]: previewForFile(file) };
  expect(made).toHaveLength(0);
  expect(JSON.parse(JSON.stringify(chip))).toEqual({ path: chip.path });
  const read = { ...chip }[localImagePreview];
  const result = read();
  expect(read()).toBe(result);
  const worker = made[0]!;
  expect(worker.posted).toEqual([{ id: 1, kind: "fileThumb", file }]);
  const thumb = { url: "data:image/png;base64,AA==", width: 80, height: 40 };
  worker.answer({ id: 1, value: thumb });
  expect(await result).toEqual(thumb);
  expect(decodedOnPage).toBe(0);
});

test("a disk thumbnail never decodes on the page when the worker cannot draw", async () => {
  const { previewForFile } = await pool();
  const result = previewForFile(new Blob(["pixels"]))();
  made[0]!.answer({ id: made[0]!.posted[0]!.id, value: undefined, unsupported: true });
  expect(await result).toBeUndefined();
  expect(decodedOnPage).toBe(0);
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
