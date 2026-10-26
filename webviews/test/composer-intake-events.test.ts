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
  let bothReady = () => {};
  const both = new Promise<void>((resolve) => (bothReady = resolve));
  void intakeFiles(
    [png("a.png"), png("b.png")],
    { allowImages: true, upload: never },
    {
      ready: (index, chip) => {
        ready.push([index, chip]);
        if (ready.length === 2) bothReady();
      },
    },
  );
  // Both chips come while the upload still hangs (intakeFiles itself never returns here).
  await both;
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

// Review (Codex): an image is a chip as soon as its preview is made, while its original still
// uploads; removing that chip stops the upload (the intake's `cancelled` asks per file).
test("an image whose chip is gone stops its original's upload", async () => {
  imageEngine();
  let removed = false;
  const chunks: string[] = [];
  const host = async (method: string, params: Record<string, unknown>) => {
    if (method === "chat.upload.begin") return { token: params.name, size: params.size, chunkSize: 512 * 1024 };
    if (method === "chat.upload.chunk") {
      chunks.push(params.token as string);
      if (chunks.length === 2) removed = true;
      return { offset: (params.offset as number) + atob(params.data as string).length };
    }
    if (method === "chat.upload.finish") return { path: `/tmp/${String(params.token)}` };
    return null;
  };
  const { uploadToMachine } = await import("../src/agent-session/acpmux/cloudUploads");
  const big = new File([new Uint8Array(8 * 1024 * 1024)], "shot.png", { type: "image/png" });
  const originals: string[] = [];
  await intakeFiles(
    [big],
    {
      allowImages: true,
      upload: (files, cancelled) => uploadToMachine(files, host, cancelled),
      // As useAttachmentIntake asks: the file is a chip, and that chip is no longer staged.
      cancelled: () => removed,
    },
    { original: (_index, path) => originals.push(path) },
  );
  expect(chunks.length).toBe(2);
  expect(originals).toEqual([]);
});

// Review (Codex): the strip shows the chat on screen. A chip pasted in chat A is out of view, not
// removed, while B is shown, so A's image keeps uploading its original.
test("an image's chip counts as removed only from the strip of the chat it was pasted in", async () => {
  const { chipRemoved } = await import("../src/agent-session/acpmux/composer/attachmentIntake");
  const base = { chip: "img", stagedHere: true, everDrawn: true, pastedIn: "A", showing: "A", strip: [] };
  expect(chipRemoved(base)).toBe(true);
  expect(chipRemoved({ ...base, showing: "B" })).toBe(false);
  expect(chipRemoved({ ...base, everDrawn: false })).toBe(false);
  expect(chipRemoved({ ...base, stagedHere: false })).toBe(false);
  expect(chipRemoved({ ...base, strip: [{ id: "img" } as never] })).toBe(false);
});
