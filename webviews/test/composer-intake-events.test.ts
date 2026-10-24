// Each file of a paste or drop resolves on its own (composer/intakeFiles.ts IntakeEvents): an image
// is its chip once its preview is made, whatever its original's upload does, a host that never says
// where the files are holds nothing past its deadline, and a cancelled file is never uploaded.
import { afterEach, expect, test } from "bun:test";
import type { ComposerAttachment } from "../src/agent-session/acpmux/attachments";
import { intakeFiles, LOCAL_PATHS_DEADLINE_MS } from "../src/agent-session/acpmux/composer/intakeFiles";

const g = globalThis as Record<string, unknown>;
function imageEngine() {
  g.createImageBitmap = async () => ({ width: 40, height: 30, close() {} });
  g.OffscreenCanvas = class {
    constructor(
      public width: number,
      public height: number,
    ) {}
    getContext() {
      return { drawImage() {}, fillRect() {}, fillStyle: "" };
    }
    async convertToBlob({ type }: { type: string }) {
      return new Blob(["pixels"], { type });
    }
  };
}
afterEach(() => {
  delete g.createImageBitmap;
  delete g.OffscreenCanvas;
});

const png = (name: string) => new File(["png"], name, { type: "image/png" });
const zip = (name: string) => new File(["zip"], name, { type: "application/zip" });
const never = <T>() => new Promise<T>(() => {});

test("an image is its chip at once while its original's upload never ends", async () => {
  imageEngine();
  const ready: [number, ComposerAttachment][] = [];
  void intakeFiles([png("a.png"), png("b.png")], { allowImages: true, upload: never }, {
    ready: (index, chip) => ready.push([index, chip]),
  });
  await new Promise((resolve) => setTimeout(resolve, 20));
  expect(ready.map(([index, chip]) => [index, chip.kind])).toEqual([
    [0, "image"],
    [1, "image"],
  ]);
});

test("a host that never says where the files are holds them no longer than its deadline", async () => {
  imageEngine();
  const started = performance.now();
  const taken = await intakeFiles([png("a.png")], { allowImages: true, localPaths: never });
  expect(taken.attachments).toHaveLength(1);
  expect(performance.now() - started).toBeLessThan(LOCAL_PATHS_DEADLINE_MS + 500);
});

test("a cancelled file is left out of the upload; the rest go, each reported by its index", async () => {
  const uploaded: string[] = [];
  const ready: number[] = [];
  const failed: number[] = [];
  await intakeFiles(
    [zip("one.zip"), zip("two.zip"), zip("three.zip")],
    {
      allowImages: true,
      cancelled: (index) => index === 1,
      upload: async (files) => {
        uploaded.push(...files.map((file) => file.name));
        return { paths: files.map((file) => `/tmp/${file.name}`) };
      },
    },
    { ready: (index) => ready.push(index), failed: (index) => failed.push(index) },
  );
  expect(uploaded).toEqual(["one.zip", "three.zip"]);
  expect(ready).toEqual([0, 2]);
  expect(failed).toEqual([]);
});

test("a failed upload fails each file it held, with the host's reason", async () => {
  const failed: [number, unknown][] = [];
  await intakeFiles(
    [zip("one.zip")],
    { allowImages: true, upload: async () => ({ error: "The disk is full." }) },
    { failed: (index, error) => failed.push([index, error]) },
  );
  expect(failed).toEqual([[0, { text: "The disk is full." }]]);
});
