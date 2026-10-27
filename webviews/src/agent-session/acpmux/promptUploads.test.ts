import { afterEach, expect, test } from "bun:test";
import { attachmentEntries, type ComposerAttachment, inlineToken, promptEntries } from "./attachments";
import {
  createNativePromptUploadTransport,
  nativePromptUploadsAvailable,
  preparePromptUploads,
  type PromptUploadTransport,
  releasePromptUploadAttachments,
  releasePromptUploadBlob,
} from "./promptUploads";
import { receivePromptUploadState } from "./promptUploadState";
const blobs = () => (globalThis as { __cmuxUploadBlobs?: Map<string, Blob> }).__cmuxUploadBlobs!;
afterEach(() => {
  for (const token of blobs()?.keys() ?? []) releasePromptUploadBlob(token, true);
});
function deferred<T = void>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => (resolve = done));
  return { promise, resolve };
}
function image(id: string, data = "AQID"): ComposerAttachment {
  return { id, kind: "image", name: id + ".png", mimeType: "image/png", size: 3, data };
}
function transport() {
  const calls: { method: string; params: any }[] = [];
  let next = 0;
  const api: PromptUploadTransport = {
    async beginBlob(params) {
      const uploadId = `01900000-0000-7000-8000-${String(++next).padStart(12, "0")}`;
      calls.push({ method: "begin", params });
      return { uploadId, offset: params.size, size: params.size };
    },
  };
  return { api, calls };
}
const prepare = (
  entries: Parameters<typeof preparePromptUploads>[0]["entries"],
  transport: PromptUploadTransport,
  options: Partial<Parameters<typeof preparePromptUploads>[0]> = {},
) =>
  preparePromptUploads({
    entries,
    features: ["promptUploads"],
    sessionId: "session",
    transport,
    cache: new Map(),
    ...options,
  });
test("feature-gated upload refs preserve order, suppress originalPath companion, and use distinct refs for duplicate bytes", async () => {
  const first = image("one");
  first.originalPath = "/tmp/original.png";
  const second = image("two", first.data);
  const entries = [
    { block: { type: "text", text: "before" } } as const,
    ...attachmentEntries(first),
    { block: { type: "text", text: "between" } } as const,
    ...attachmentEntries(second),
  ];
  const t = transport();
  const blockIndexes = new Map<number, number>();
  const prepared = await prepare(entries, t.api, { blockIndexes });
  expect([...blockIndexes]).toEqual([
    [0, 0],
    [1, 1],
    [3, 2],
    [4, 3],
  ]);
  expect(prepared.map((part) => part.type)).toEqual(["text", "image", "text", "image"]);
  const refs = prepared.filter((part) => part.type === "image");
  expect(refs.every((part) => !("data" in part) && part._meta?.acpmux.upload.uploadId)).toBe(true);
  expect(refs[0]!._meta!.acpmux.upload.uploadId).not.toBe(refs[1]!._meta!.acpmux.upload.uploadId);
});
test("uploadFrames uses one page token and does not send Blob bytes through the binding", async () => {
  const one = image("one");
  const calls: { method: string; params: any }[] = [];
  const transport: PromptUploadTransport = {
    async beginBlob(params) {
      calls.push({ method: "beginBlob", params });
      const registry = blobs();
      expect(registry?.get(params.token)).toBeInstanceOf(Blob);
      expect(new Uint8Array(await registry!.get(params.token)!.arrayBuffer())).toEqual(new Uint8Array([1, 2, 3]));
      return { uploadId: "01900000-0000-7000-8000-000000000001", size: params.size };
    },
  };
  const prepared = await prepare(promptEntries("ship", [one]), transport, {
    features: ["promptUploads", "uploadFrames"],
  });
  expect(calls).toHaveLength(1);
  expect(calls[0]!.params).toMatchObject({ sessionId: "session", fileName: "one.png", mimeType: "image/png", size: 3 });
  expect(prepared[1]).toMatchObject({
    type: "image",
    _meta: { acpmux: { upload: { uploadId: "01900000-0000-7000-8000-000000000001", fileName: "one.png" } } },
  });
  expect(prepared[1]).not.toHaveProperty("data");
  expect(blobs()?.size).toBe(1);
  releasePromptUploadBlob(calls[0]!.params.token);
  expect(blobs()?.size).toBe(0);
});
test("failed attempts retry with a fresh token on the same Blob and ignore late old state", async () => {
  const one = image("one");
  const tokens: string[] = [];
  const acquired = deferred();
  const transport = createNativePromptUploadTransport(
    async (op, params) => {
      const token = params.token as string;
      if (op.endsWith(".begin")) {
        tokens.push(token);
        if (tokens.length === 1)
          receivePromptUploadState({
            token,
            state: "failed",
            size: 3,
            error: { code: "busy", message: "native busy" },
          });
        else acquired.resolve();
        return { uploadId: "pending" } as any;
      }
      return { token, state: "uploading", size: 3 } as any;
    },
    async () => {},
  );
  const options = { cache: new Map(), tokenCache: new Map(), promptId: "same-prompt", ticket: "send-ticket" };
  const send = () => prepare(promptEntries("ship", [one]), transport, options);
  await expect(send()).rejects.toThrow("native busy");
  const blob = blobs().get(tokens[0]!);
  let settled = false;
  const retry = send().then((result) => {
    settled = true;
    return result;
  });
  void retry.catch(() => undefined);
  await acquired.promise;
  expect(tokens[1]).not.toBe(tokens[0]);
  expect(blobs().get(tokens[1]!)).toBe(blob);
  expect(blobs().has(tokens[0]!)).toBe(false);
  receivePromptUploadState({ token: tokens[0], state: "finished", uploadId: "old", size: 3 });
  await Promise.resolve();
  expect(settled).toBe(false);
  receivePromptUploadState({ token: tokens[1], state: "finished", uploadId: "new", size: 3 });
  const prepared = await retry;
  expect(prepared[1]).toMatchObject({ _meta: { acpmux: { upload: { uploadId: "new" } } } });
  expect(blobs().size).toBe(1);
  releasePromptUploadBlob(tokens[1]!);
  expect(blobs().size).toBe(0);
});
test("a cancelled waiter leaves a shared upload cached for its surviving retry", async () => {
  const one = image("one");
  const done = deferred();
  let calls = 0;
  const transport: PromptUploadTransport = {
    async beginBlob(params) {
      calls += 1;
      await done.promise;
      return { uploadId: "shared", size: params.size };
    },
  };
  const common = {
    entries: promptEntries("ship", [one]),
    features: ["promptUploads"],
    sessionId: "session",
    transport,
    cache: new Map(),
    tokenCache: new Map(),
  };
  let cancelled = false;
  const first = preparePromptUploads({ ...common, isCancelled: () => cancelled });
  const second = preparePromptUploads(common);
  cancelled = true;
  releasePromptUploadAttachments([one.id]);
  done.resolve();
  await expect(first).rejects.toThrow("closed");
  const prepared = await second;
  const retry = await preparePromptUploads(common);
  expect(retry).toEqual(prepared);
  expect(calls).toBe(1);
});
test("an older daemon keeps the existing inline block shape when upload refs are unavailable", async () => {
  const one = image("one");
  const entries = promptEntries("ship", [one]);
  const t = transport();
  const prepared = await prepare(entries, t.api, { features: [] });
  expect(prepared).toEqual(entries.map((e) => e.block));
  expect(t.calls).toHaveLength(0);
});
test("the adapter does not impose a client attachment-count cap", async () => {
  const attachments = Array.from({ length: 40 }, (_, index) => image(String(index)));
  const t = transport();
  const prepared = await prepare(attachments.flatMap(attachmentEntries), t.api);
  expect(prepared.filter((part) => part.type === "image")).toHaveLength(40);
});
test("document bytes become the exact resource upload URI with metadata", async () => {
  const t = transport();
  const prepared = await prepare(
    [{ block: { type: "document", mimeType: "application/pdf", data: "AQID", name: "report.pdf" } }],
    t.api,
  );
  expect(prepared[0]).toMatchObject({
    type: "resource_link",
    uri: "acpmux-upload:01900000-0000-7000-8000-000000000001",
    name: "report.pdf",
  });
  expect((prepared[0] as any)._meta.acpmux.upload).toEqual({
    uploadId: "01900000-0000-7000-8000-000000000001",
    fileName: "report.pdf",
  });
  expect(prepared[0]).not.toHaveProperty("data");
});
test("reordering same-name equal-size attachments preserves their upload identities", async () => {
  const first = { ...image("one"), name: "same.png" };
  const second = { ...image("two", "BAUG"), name: "same.png" };
  const t = transport();
  const cache = new Map();
  const prepareOrder = (order: ComposerAttachment[]) =>
    prepare(promptEntries(order.map((a) => inlineToken(a.id)).join(""), [first, second]), t.api, { cache });
  const initial = await prepareOrder([second, first]);
  const reordered = await prepareOrder([first, second]);
  expect(reordered.map((b: any) => b._meta.acpmux.upload.uploadId)).toEqual(
    initial.map((b: any) => b._meta.acpmux.upload.uploadId).reverse(),
  );
});
test("an edited attachment of the same size cannot reuse its old bytes", async () => {
  const one = image("one");
  const t = transport();
  const cache = new Map();
  const prepareEdited = (a: ComposerAttachment) => prepare(promptEntries("", [a]), t.api, { cache });
  const old = await prepareEdited(one);
  const edited = await prepareEdited({ ...one, data: "BAUG" });
  expect((edited[0] as any)._meta.acpmux.upload.uploadId).not.toBe((old[0] as any)._meta.acpmux.upload.uploadId);
});
test("only an image's own originalPath companion is suppressed", async () => {
  const one = { ...image("one"), originalPath: "/tmp/original.png", originalName: "original.png" };
  const link: ComposerAttachment = {
    id: "link",
    kind: "link",
    name: "original.png",
    mimeType: "",
    size: 0,
    path: "/other/original.png",
  };
  const t = transport();
  const prepared = await prepare(promptEntries("", [one, link]), t.api);
  expect(prepared.map((b) => b.type)).toEqual(["image", "resource_link"]);
  expect(prepared[1]).toMatchObject({ uri: "file:///other/original.png" });
});
test("native beginBlob must acknowledge terminal completion before a ref is sent", async () => {
  const one = image("one");
  await expect(
    prepare(promptEntries("", [one]), {
      async beginBlob() {
        return { uploadId: "partial", size: 3, offset: 1 };
      },
    }),
  ).rejects.toThrow("incomplete");
});
test("a changed retained Blob is replaced and explicit removal releases its token", async () => {
  const one = image("retained");
  const tokens: string[] = [];
  const cache = new Map();
  const tokenCache = new Map();
  const transport: PromptUploadTransport = {
    async beginBlob({ token }) {
      tokens.push(token);
      throw new Error("busy");
    },
  };
  const prepareRetained = (a: ComposerAttachment) => prepare(promptEntries("", [a]), transport, { cache, tokenCache });
  await expect(prepareRetained(one)).rejects.toThrow("busy");
  await expect(prepareRetained({ ...one, data: "BAUG" })).rejects.toThrow("busy");
  const registry = blobs()!;
  expect(tokens[1]).not.toBe(tokens[0]);
  expect(registry.has(tokens[0]!)).toBe(false);
  expect(new Uint8Array(await registry.get(tokens[1]!)!.arrayBuffer())).toEqual(new Uint8Array([4, 5, 6]));
  releasePromptUploadAttachments([one.id]);
  expect(registry.has(tokens[1]!)).toBe(false);
});
test("a replaced native pull releases its Blob without overwriting the newer cache", async () => {
  const ready = deferred<string>();
  const done = deferred();
  const one = image("handoff");
  const cache = new Map();
  const tokenCache = new Map();
  const sending = prepare(
    promptEntries("", [one]),
    {
      async beginBlob(params) {
        ready.resolve(params.token);
        await done.promise;
        return { uploadId: "handoff", size: params.size };
      },
    },
    { cache, tokenCache },
  );
  const token = await ready.promise;
  let replacementToken = "";
  const replaced = prepare(
    promptEntries("", [{ ...one, data: "BAUG" }]),
    {
      async beginBlob(params) {
        replacementToken = params.token;
        return { uploadId: "replacement", size: params.size };
      },
    },
    { cache, tokenCache },
  );
  await replaced;
  expect(cache.get("session:handoff")?.uploadId).toBe("replacement");
  expect(blobs()?.has(replacementToken)).toBe(true);
  expect(blobs()?.has(token)).toBe(true);
  done.resolve();
  await sending;
  expect(cache.get("session:handoff")?.uploadId).toBe("replacement");
  expect(blobs()?.has(token)).toBe(false);
});
test("closing a preparation after native acquired its first Blob cannot upload the next attachment", async () => {
  const ready = deferred();
  const done = deferred();
  let closed = false;
  let count = 0;
  const sending = preparePromptUploads({
    entries: promptEntries("", [image("cancel-a"), image("cancel-b")]),
    features: ["promptUploads"],
    sessionId: "session",
    cache: new Map(),
    isCancelled: () => closed,
    transport: {
      async beginBlob(params) {
        count += 1;
        ready.resolve();
        await done.promise;
        return {
          uploadId: "cancelled",
          size: params.size,
        };
      },
    },
  });
  await ready.promise;
  closed = true;
  done.resolve();
  await expect(sending).rejects.toThrow("closed");
  expect(count).toBe(1);
});
test("WebKit/legacy hosts keep inline blocks when native Blob upload capability is absent", () => {
  const scope = globalThis as { __cmuxNativePromptUploads?: boolean };
  const previous = scope.__cmuxNativePromptUploads;
  delete scope.__cmuxNativePromptUploads;
  expect(nativePromptUploadsAvailable()).toBe(false);
  scope.__cmuxNativePromptUploads = previous;
});

test("explicit removal cancels the native pull without waiting for a terminal push", async () => {
  const one = image("abort-native");
  const acquired = deferred();
  let cancelled = false;
  let reject!: (error: Error) => void;
  const transport: PromptUploadTransport = {
    async beginBlob() {
      acquired.resolve();
      return new Promise((_, fail) => {
        reject = fail;
      });
    },
    async cancelBlob() {
      cancelled = true;
      reject(new Error("cancelled"));
    },
  };
  const sending = prepare(promptEntries("", [one]), transport);
  await acquired.promise;
  releasePromptUploadAttachments([one.id]);
  await Promise.resolve();
  expect(cancelled).toBe(true);
  if (cancelled) await expect(sending).rejects.toThrow("cancelled");
  else reject(new Error("cleanup"));
  await sending.catch(() => undefined);
});
