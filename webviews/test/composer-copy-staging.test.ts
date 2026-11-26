import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { JSDOM } from "jsdom";
import { copyItem, pastePlan, type ComposerCopy } from "../src/agent-session/acpmux/composer/composerCopy";
import { stageComposerCopy } from "../src/agent-session/acpmux/composer/composerCopyStage";

const MiB = 1024 * 1024;

function repeatedHash(byte: number, size: number) {
  const hash = createHash("sha256");
  const chunk = Buffer.alloc(192 * 1024, byte);
  for (let offset = 0; offset < size; offset += chunk.length)
    hash.update(chunk.subarray(0, Math.min(chunk.length, size - offset)));
  return hash.digest("hex");
}

test("copy retains 128 files, a 33 MiB binary, 9 MiB text and more than 128 MiB in full, in order", async () => {
  const binary = Buffer.alloc(33 * MiB, 0x61).toString("base64");
  const item = copyItem({
    id: "large",
    kind: "document",
    name: "large.bin",
    mimeType: "application/octet-stream",
    size: 33 * MiB,
    data: binary,
  });
  expect(item).toBeDefined(); // the old web cap silently omitted this attachment
  const text = "b".repeat(9 * MiB);
  const smaller = "c".repeat(MiB);
  const copy: ComposerCopy = {
    text: "s".repeat(9 * MiB),
    parts: [],
    items: [
      item!,
      { name: "large.txt", mimeType: "text/plain", text },
      ...Array.from({ length: 126 }, (_, i) => ({ name: `${i}.txt`, mimeType: "text/plain", text: smaller })),
    ],
  };
  const expected = [
    repeatedHash(0x73, 9 * MiB),
    createHash("sha256").update("[]").digest("hex"),
    repeatedHash(0x61, 33 * MiB),
    repeatedHash(0x62, 9 * MiB),
    ...Array(126).fill(repeatedHash(0x63, MiB)),
  ];
  const stages = new Map<string, { size: number; offset: number; hash: ReturnType<typeof createHash> }>();
  const complete: string[] = [];
  let maxChunk = 0;
  let finalItems: { reference?: string; name: string }[] = [];
  let progress = 0;
  const call = async <T>(method: string, params: Record<string, unknown>): Promise<T> => {
    if (method === "composer.copy.begin") {
      const token = crypto.randomUUID();
      stages.set(token, { size: Number(params.size), offset: 0, hash: createHash("sha256") });
      return { token, batchToken: "batch", chunkSize: 512 * 1024 } as T;
    }
    if (method === "composer.copy.chunk") {
      const stage = stages.get(String(params.token))!;
      const bytes = Buffer.from(String(params.data), "base64");
      expect(params.offset).toBe(stage.offset);
      maxChunk = Math.max(maxChunk, bytes.length);
      stage.hash.update(bytes);
      stage.offset += bytes.length;
      return { offset: stage.offset } as T;
    }
    if (method === "composer.copy.finish") {
      const token = String(params.token);
      const stage = stages.get(token)!;
      expect(stage.offset).toBe(stage.size);
      complete.push(stage.hash.digest("hex"));
      return { reference: token } as T;
    }
    expect(method).toBe("composer.copy.staged");
    finalItems = params.items as typeof finalItems;
    expect(params.text).toBe([...stages.keys()][0]);
    return { copyID: "same-copy", files: finalItems.map((item, index) => ({ item: index, name: item.name })) } as T;
  };
  const reply = await stageComposerCopy(copy, call, {
    progress(written, total) {
      expect(written).toBeGreaterThanOrEqual(progress);
      progress = written;
      expect(total).toBe(177 * MiB + 2);
    },
  });
  expect(reply.copyID).toBe("same-copy");
  expect(complete).toEqual(expected);
  expect(finalItems.map((item) => item.name)).toEqual(copy.items.map((item) => item.name));
  expect(finalItems.map((item) => item.reference)).toEqual([...stages.keys()].slice(2));
  expect(finalItems).toHaveLength(128);
  expect(maxChunk).toBeLessThanOrEqual(192 * 1024);
  expect(progress).toBe(177 * MiB + 2);
});

test("UTF-8 across a chunk boundary retains complete surrogate pairs", async () => {
  const text = "x".repeat(65535) + "🌏é".repeat(100000);
  let received = "";
  let isAttachment = false;
  const decoder = new TextDecoder();
  await stageComposerCopy(
    { text: "", parts: [], items: [{ name: "unicode.txt", mimeType: "text/plain", text }] },
    async <T>(method: string, params: Record<string, unknown>): Promise<T> => {
      if (method.endsWith("begin")) {
        isAttachment = params.name === "copy-2";
        return { token: crypto.randomUUID(), batchToken: "batch", chunkSize: 512 * 1024 } as T;
      }
      if (method.endsWith("chunk")) {
        const bytes = Buffer.from(String(params.data), "base64");
        if (isAttachment) received += decoder.decode(bytes);
        return { offset: Number(params.offset) + bytes.length } as T;
      }
      if (method.endsWith("finish")) return { reference: params.token } as T;
      return {} as T;
    },
  );
  expect(received).toBe(text);
});

test("cancel cleans every stage and never commits a partial clipboard", async () => {
  const controller = new AbortController();
  const cancelled: string[] = [];
  let committed = false;
  const copy: ComposerCopy = {
    text: "",
    parts: [],
    items: [{ name: "large.txt", mimeType: "text/plain", text: "x".repeat(4 * MiB) }],
  };
  await expect(
    stageComposerCopy(
      copy,
      async <T>(method: string, params: Record<string, unknown>): Promise<T> => {
        if (method.endsWith("begin"))
          return { token: crypto.randomUUID(), batchToken: "batch", chunkSize: 512 * 1024 } as T;
        if (method.endsWith("finish")) return { reference: params.token } as T;
        if (method.endsWith("cancel")) {
          cancelled.push(String(params.token));
          return {} as T;
        }
        if (method.endsWith("chunk")) {
          controller.abort();
          return { offset: Number(params.offset) + Buffer.from(String(params.data), "base64").length } as T;
        }
        committed = true;
        return {} as T;
      },
      { signal: controller.signal },
    ),
  ).rejects.toThrow();
  expect(cancelled).toHaveLength(2);
  expect(committed).toBe(false);
});

test("a 9 MiB selection pastes in order when browser storage refuses it and plain text is hidden", () => {
  const dom = new JSDOM("<!doctype html>");
  const hadDocument = "document" in globalThis;
  const previous = globalThis.document;
  globalThis.document = dom.window.document;
  try {
    const text = "a".repeat(9 * MiB) + "<&🌏>";
    const split = 4 * MiB;
    const order = [{ range: [0, split] }, { item: 0, id: "large" }, { range: [split, text.length] }];
    const escape = (value: string) =>
      value.replaceAll("&", "&amp;").replaceAll('"', "&quot;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");
    const copyID = crypto.randomUUID();
    const html = `<span data-cmux-composer-copy="${copyID}">${escape(text)}</span><span hidden data-cmux-composer-order="${escape(JSON.stringify(order))}" data-cmux-composer-files="${escape(JSON.stringify(["large.bin"]))}"></span>`;
    const file = new File(["complete file reference"], "large.bin");
    const storage = {
      getItem() {
        throw new DOMException("Storage quota exceeded", "QuotaExceededError");
      },
    } as unknown as Storage;
    const plan = pastePlan(
      { files: [file], getData: (type: string) => (type === "text/html" ? html : "") } as unknown as DataTransfer,
      () => false,
      storage,
    );
    expect(plan).toHaveLength(3);
    expect(plan?.[1]).toEqual({ file });
    const pasted = plan?.flatMap((part) => ("text" in part ? [part.text] : [])).join("");
    expect(
      createHash("sha256")
        .update(pasted ?? "")
        .digest("hex"),
    ).toBe(createHash("sha256").update(text).digest("hex"));
    expect(plan?.[0]).toEqual({ text: text.slice(0, split) });
    expect(plan?.[2]).toEqual({ text: text.slice(split) });
  } finally {
    if (hadDocument) globalThis.document = previous;
    else Reflect.deleteProperty(globalThis, "document");
    dom.window.close();
  }
});

test("a 4 MiB clipboard attachment crosses the bridge in bounded messages", async () => {
  const item = {
    name: "copy.bin",
    mimeType: "application/octet-stream",
    data: Buffer.alloc(4 * MiB, 0x61).toString("base64"),
  };
  const copy: ComposerCopy = { text: "", parts: [], items: [item] };
  const before = Buffer.byteLength(JSON.stringify({ text: copy.text, items: copy.items }));
  let after = 0;
  await stageComposerCopy(copy, async <T>(method: string, params: Record<string, unknown>): Promise<T> => {
    after = Math.max(after, Buffer.byteLength(JSON.stringify(params)));
    if (method.endsWith("begin"))
      return { token: crypto.randomUUID(), batchToken: "batch", chunkSize: 512 * 1024 } as T;
    if (method.endsWith("chunk"))
      return { offset: Number(params.offset) + Buffer.from(String(params.data), "base64").length } as T;
    if (method.endsWith("finish")) return { reference: String(params.token) } as T;
    return { copyID: "bounded", files: [{ item: 0, name: item.name }] } as T;
  });
  expect(after).toBeLessThan(270 * 1024);
  expect(after).toBeLessThan(before / 20);
  console.log(
    `Clipboard bridge payload bytes: before=${before}, after=${after}, delta=${((after / before - 1) * 100).toFixed(2)}% (same 4 MiB fixture)`,
  );
});
