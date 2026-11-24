import { expect, test } from "bun:test";
import { draftShapeOf } from "../src/agent-session/acpmux/composer/draftMediaShape";

test("a format without a header reader has its box at once, without opening the file", () => {
  const file = new File([], "capture.heic", { type: "image/heic" });
  let reads = 0;
  file.slice = () => {
    reads++;
    return new Blob();
  };
  expect(draftShapeOf(file, false).read()).toBe(1);
  expect(reads).toBe(0);
});

test("a local chip moved before its header arrives gets a visible, stable box in its new chat", async () => {
  const file = new File([], "capture.png", { type: "image/png" });
  let finish!: (header: ArrayBuffer) => void;
  const header = new Promise<ArrayBuffer>((resolve) => {
    finish = resolve;
  });
  file.slice = () => Object.assign(new Blob(), { arrayBuffer: () => header });
  const frames = new Map<number, FrameRequestCallback>();
  const request = globalThis.requestAnimationFrame;
  const cancel = globalThis.cancelAnimationFrame;
  let id = 0;
  globalThis.requestAnimationFrame = (paint) => {
    frames.set(++id, paint);
    return id;
  };
  globalThis.cancelAnimationFrame = (handle) => {
    frames.delete(handle);
  };
  try {
    const shape = draftShapeOf(file, false);
    let oldPaints = 0;
    shape.subscribe(() => oldPaints++)();
    expect(frames.size).toBe(0);
    let newPaints = 0;
    const detach = shape.subscribe(() => newPaints++);
    for (let tick = 0; tick < 3; tick++) {
      const paint = frames.get(id)!;
      frames.delete(id);
      paint(tick * 16);
    }
    expect(shape.read()).toBe(1);
    expect(shape.forSend()).toBe(1);
    expect(oldPaints).toBe(0);
    expect(newPaints).toBe(1);
    // A valid wide PNG header that arrives late cannot shift what the new chat has already drawn.
    const bytes = new Uint8Array(24);
    bytes.set([137, 80, 78, 71], 0);
    bytes.set([73, 72, 68, 82], 12);
    const dimensions = new DataView(bytes.buffer);
    dimensions.setUint32(16, 200);
    dimensions.setUint32(20, 100);
    finish(bytes.buffer);
    await new Promise<void>((resolve) => setImmediate(resolve));
    expect(shape.read()).toBe(1);
    expect(newPaints).toBe(1);
    expect(shape.forSend()).toBe(1);
    detach();
  } finally {
    globalThis.requestAnimationFrame = request;
    globalThis.cancelAnimationFrame = cancel;
  }
});
