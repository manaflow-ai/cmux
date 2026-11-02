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

/// An image engine whose decoding waits for `decoded()`, as a slow preview does.
function slowImageEngine() {
  imageEngine();
  let decoded = () => {};
  const done = new Promise<void>((resolve) => (decoded = resolve));
  g.createImageBitmap = async () => {
    await done;
    return { width: 40, height: 30, close() {} };
  };
  return () => decoded();
}

/// A promise and the call that settles it.
function signal() {
  let fire = () => {};
  const fired = new Promise<void>((resolve) => (fire = resolve));
  return { fire, fired };
}

// An ordinary file's upload never waits for a sibling image's preview: the batch's one ordered
// upload starts while the preview is still being made, and the image's original keeps its place.
// Before the fix the upload never starts while the preview hangs, and the test times out.
test("a file's upload starts while a sibling image's preview is still being made", async () => {
  const decoded = slowImageEngine();
  const fileChip = signal();
  const uploaded: string[][] = [];
  const events: string[] = [];
  const taken = intakeFiles(
    [png("shot.png"), zip("notes.zip")],
    {
      allowImages: true,
      upload: async (files) => {
        uploaded.push(files.map((file) => file.name));
        return { paths: files.map((file) => `/tmp/${file.name}`) };
      },
    },
    {
      ready: (index, chip) => {
        events.push(`ready ${index} ${chip.kind}`);
        if (index === 1) fileChip.fire();
      },
      uploading: (index) => events.push(`uploading ${index}`),
      original: (index, path) => events.push(`original ${index} ${path}`),
    },
  );
  // The file is its chip once its upload is done, while the image's preview is still being made.
  await fileChip.fired;
  expect(uploaded).toEqual([["shot.png", "notes.zip"]]);
  expect(events).toContain("ready 1 link");
  // The image is not yet a chip, and its tile still holds a send until it is.
  expect(events).not.toContain("ready 0 image");
  expect(events).not.toContain("uploading 0");
  decoded();
  const result = await taken;
  // The image's original pairs with its preview once that is made.
  expect(events.indexOf("original 0 /tmp/shot.png")).toBeGreaterThan(events.indexOf("ready 0 image"));
  expect(result.attachments.find((chip) => chip.kind === "image")?.originalPath).toBe("/tmp/shot.png");
});

test("a file with a known path is its link at once, and a cancelled one stays out, while an image decodes", async () => {
  const decoded = slowImageEngine();
  const uploadedChip = signal();
  const uploaded: string[][] = [];
  const ready: number[] = [];
  const taken = intakeFiles(
    [png("shot.png"), zip("local.zip"), zip("gone.zip"), zip("sent.zip")],
    {
      allowImages: true,
      localPaths: async (files) =>
        files.map((file, index) => (index === 1 ? { path: `/Users/me/${file.name}` } : undefined)) as never,
      cancelled: (index) => index === 2,
      upload: async (files) => {
        uploaded.push(files.map((file) => file.name));
        return { paths: files.map((file) => `/tmp/${file.name}`) };
      },
    },
    {
      ready: (index) => {
        ready.push(index);
        if (index === 3) uploadedChip.fire();
      },
    },
  );
  await uploadedChip.fired;
  expect(uploaded).toEqual([["shot.png", "sent.zip"]]);
  expect(ready).toEqual([1, 3]);
  decoded();
  await taken;
  expect([...ready].sort((a, b) => a - b)).toEqual([0, 1, 3]);
});

// Review (Astra): a slow image the host knows the path of still held its siblings' upload.
test("a file's upload never waits for a sibling image the host knows the path of", async () => {
  const decoded = slowImageEngine();
  const fileChip = signal();
  const uploaded: string[][] = [];
  const ready: string[] = [];
  const taken = intakeFiles(
    [png("shot.png"), zip("notes.zip")],
    {
      allowImages: true,
      localPaths: async (files) =>
        files.map((file, index) => (index === 0 ? { path: `/Users/me/${file.name}` } : undefined)) as never,
      upload: async (files) => {
        uploaded.push(files.map((file) => file.name));
        return { paths: files.map((file) => `/tmp/${file.name}`) };
      },
    },
    {
      ready: (index, chip) => {
        ready.push(`${index} ${chip.kind}`);
        if (index === 1) fileChip.fire();
      },
    },
  );
  await fileChip.fired;
  expect(uploaded).toEqual([["notes.zip"]]);
  expect(ready).toEqual(["1 link"]);
  decoded();
  const result = await taken;
  expect(ready).toEqual(["1 link", "0 image"]);
  expect(result.attachments.find((chip) => chip.kind === "image")?.originalPath).toBe("/Users/me/shot.png");
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
  const base = {
    chip: "img",
    stagedHere: true,
    everDrawn: true,
    pastedIn: "A",
    showing: "A",
    strip: [],
  };
  expect(chipRemoved(base)).toBe(true);
  expect(chipRemoved({ ...base, showing: "B" })).toBe(false);
  expect(chipRemoved({ ...base, everDrawn: false })).toBe(false);
  expect(chipRemoved({ ...base, stagedHere: false })).toBe(false);
  expect(chipRemoved({ ...base, strip: [{ id: "img" } as never] })).toBe(false);
});

// Review (Astra): a chip ready after the composer left its chat goes to that chat's kept chips, one
// handoff per chip. Ready chips of one batch arrive at their own times, so two handoffs can overlap:
// each must see the other's chip, never write over it.
test("chips handed to a chat the composer left all stay, in the order they were handed", async () => {
  const { keepElsewhere } = await import("../src/agent-session/acpmux/composer/keptAttachments");
  let kept: ComposerAttachment[] = [{ id: "old" } as ComposerAttachment];
  const store = {
    read: async () => {
      await Promise.resolve();
      return kept;
    },
    write: async (_chat: string, chips: ComposerAttachment[]) => {
      await Promise.resolve();
      kept = chips;
      return { held: [] };
    },
  };
  const chip = (id: string) => ({ id, kind: "link", name: id, mimeType: "text/plain", size: 1 }) as ComposerAttachment;
  await Promise.all([keepElsewhere(store, "A", [chip("file")]), keepElsewhere(store, "A", [chip("image")])]);
  expect(kept.map((attachment) => attachment.id)).toEqual(["old", "file", "image"]);
});
