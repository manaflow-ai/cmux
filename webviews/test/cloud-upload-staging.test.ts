import { expect, test } from "bun:test";
import { uploadToMachine } from "../src/agent-session/acpmux/cloudUploads";

function host(chunkSize = 4) {
  const calls: [string, Record<string, unknown>][] = [];
  const uploads = new Map<string, { name: string; size: number; offset: number; data: string }>();
  const call = async (method: string, params: Record<string, unknown>): Promise<unknown> => {
    calls.push([method, params]);
    if (method === "chat.upload.begin") {
      const token = String(uploads.size);
      uploads.set(token, { name: String(params.name), size: Number(params.size), offset: 0, data: "" });
      return { token, size: params.size, chunkSize, ...(params.batch ? { batchToken: "selected-files" } : {}) };
    }
    const upload = uploads.get(String(params.token))!;
    if (method === "chat.upload.chunk") {
      expect(params.offset).toBe(upload.offset);
      const bytes = atob(String(params.data));
      upload.data += bytes;
      upload.offset += bytes.length;
      return { offset: upload.offset };
    }
    if (method === "chat.upload.finish") {
      expect(upload.offset).toBe(upload.size);
      return { path: `/session/${String(params.token)}/${upload.name}` };
    }
    return {};
  };
  return { calls, uploads, call };
}

test("uploads bounded chunks with offsets and finishes the original file", async () => {
  const native = host();
  const file = new File(["0123456789"], "notes.txt");
  Object.defineProperty(file, "arrayBuffer", {
    value: () => {
      throw new Error("whole file read");
    },
  });
  expect(await uploadToMachine([file], native.call)).toEqual({ paths: ["/session/0/notes.txt"] });
  expect(native.uploads.get("0")?.data).toBe("0123456789");
  expect(native.calls.filter(([method]) => method === "chat.upload.chunk").map(([, params]) => params.offset)).toEqual([
    0, 4, 8,
  ]);
  expect(native.calls.some(([method]) => method === "chat.upload")).toBe(false);
});

test("does not impose a 64 MiB file or request limit and never reads the whole file", async () => {
  const size = 80 * 1024 * 1024;
  const file = new File([], "large.bin");
  Object.defineProperty(file, "size", { value: size });
  Object.defineProperty(file, "arrayBuffer", {
    value: () => {
      throw new Error("whole file read");
    },
  });
  Object.defineProperty(file, "slice", { value: (from: number, to: number) => new Blob([new Uint8Array(to - from)]) });
  let offset = 0;
  let chunks = 0;
  expect(
    await uploadToMachine([file], async (method, params) => {
      if (method === "chat.upload.begin") return { token: "large", size, chunkSize: 512 * 1024 };
      if (method === "chat.upload.chunk") {
        expect(params.offset).toBe(offset);
        const length = atob(String(params.data)).length;
        expect(length).toBeLessThanOrEqual(512 * 1024);
        offset += length;
        chunks++;
        return { offset };
      }
      if (method === "chat.upload.finish") return { path: "/session/large.bin" };
      throw new Error(`Unexpected method ${method}`);
    }),
  ).toEqual({ paths: ["/session/large.bin"] });
  expect(offset).toBe(size);
  expect(chunks).toBe(160);
});

test("a selected batch keeps every file, including repeated names and more than ten files", async () => {
  const native = host();
  const files = Array.from({ length: 12 }, () => new File(["x"], "notes.txt"));
  expect(await uploadToMachine(files, native.call)).toEqual({
    paths: files.map((_, index) => `/session/${index}/notes.txt`),
  });
  const begins = native.calls.filter(([method]) => method === "chat.upload.begin").map(([, params]) => params);
  expect(begins[0]?.batch).toEqual(files.map(({ name, size }) => ({ name, size })));
  expect(begins.slice(1).every((params) => params.batchToken === "selected-files")).toBe(true);
});

test("an invalid acknowledgement cancels staging and never finishes or falls back", async () => {
  const native = host();
  const result = await uploadToMachine([new File(["hello"], "notes.txt")], (method, params) =>
    method === "chat.upload.chunk" ? Promise.resolve({ offset: 99 }) : native.call(method, params),
  );
  expect(result).toEqual({ error: "The upload could not be completed." });
  expect(native.calls.map(([method]) => method)).toEqual(["chat.upload.begin", "chat.upload.cancel"]);
});

test("a failed chunk cancels once, preserving the native error", async () => {
  const native = host();
  const result = await uploadToMachine([new File(["hello"], "notes.txt")], (method, params) =>
    method === "chat.upload.chunk" ? Promise.reject(new Error("Disconnected")) : native.call(method, params),
  );
  expect(result).toEqual({ error: "Disconnected" });
  expect(native.calls.at(-1)?.[0]).toBe("chat.upload.cancel");
});

test("only an unavailable staging method chooses legacy upload", async () => {
  const calls: string[] = [];
  const result = await uploadToMachine([new File(["hello"], "notes.txt")], async (method) => {
    calls.push(method);
    if (method === "chat.upload.begin") throw { code: "unsupported" };
    return { uploads: [{ path: "/session/notes.txt" }] };
  });
  expect(result).toEqual({ paths: ["/session/notes.txt"] });
  expect(calls).toEqual(["chat.upload.begin", "chat.upload"]);
});

test("a storage quota refusal stays a refusal, with no legacy bypass", async () => {
  const calls: string[] = [];
  const result = await uploadToMachine([new File(["hello"], "notes.txt")], async (method) => {
    calls.push(method);
    throw new Error("Storage quota exceeded");
  });
  expect(result).toEqual({ error: "Storage quota exceeded" });
  expect(calls).toEqual(["chat.upload.begin"]);
});
