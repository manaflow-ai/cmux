import { afterEach, describe, expect, test } from "bun:test";
import {
  AttachmentService,
  GENERIC_FILE_TYPE,
  hashFile,
  looksLikeText,
  refusal,
  resolvedType,
} from "../src/pages/home-channels/attachmentService";

// Any file attaches (Lawrence 2026-10-20, "“index.html” can't be attached ... need to fix this"):
// UTF-8 text of any name goes as text/plain, other bytes as a generic file; only empty files refuse.
const bytes = (text: string) => new TextEncoder().encode(text);

describe("Channels attachments: any file", () => {
  afterEach(() => {
    delete (globalThis as { createImageBitmap?: unknown }).createImageBitmap;
  });
  test("an HTML page, a dotfile and an extensionless file go as text", () => {
    for (const [name, type] of [
      ["index.html", "text/html"],
      [".zshrc", ""],
      ["Makefile", ""],
      ["main.rs", "text/rust"],
    ]) {
      const body = bytes("<p>héllo ✓</p>\n");
      const file = new File([body], name, { type });
      expect(refusal(file)).toBeUndefined();
      expect(resolvedType(file, body)).toBe("text/plain");
    }
  });

  test("an arbitrary binary goes as a generic file", () => {
    const body = new Uint8Array([0x53, 0x51, 0x4c, 0x00, 0x03, 0xff, 0xfe, 0x10]);
    const file = new File([body], "state.sqlite", { type: "" });
    expect(refusal(file)).toBeUndefined();
    expect(resolvedType(file, body)).toBe(GENERIC_FILE_TYPE);
  });

  test("listed types keep their own type", () => {
    const body = bytes("{}");
    expect(resolvedType(new File([body], "a.json", { type: "application/json" }), body)).toBe("application/json");
  });

  test("a character cut at the end of a prefix still reads as text", () => {
    const text = bytes("añb✓");
    expect(looksLikeText(text.subarray(0, text.length - 1), false)).toBe(true);
    expect(looksLikeText(text.subarray(0, text.length - 1), true)).toBe(false);
  });

  test("a UTF-8 character just beyond the sniff prefix remains text", () => {
    const body = new Uint8Array([...bytes("a".repeat(65_535)), ...bytes("é")]);
    const file = new File([body], "boundary.txt", { type: "" });
    expect(resolvedType(file, body.subarray(0, 64 * 1024))).toBe("text/plain");
  });

  test("an empty file is refused but a file beyond the former cap is accepted", () => {
    expect(refusal(new File([], "empty.txt"))).toBe("size");
    expect(refusal({ size: 100 * 1024 * 1024 + 1 } as File)).toBeUndefined();
  });

  test("streamed hashes match SHA-256 across padding boundaries", async () => {
    const vectors = [
      "",
      "a".repeat(55),
      "a".repeat(56),
      "a".repeat(64),
      "a".repeat(127),
      "a".repeat(3 * 1024 * 1024 + 127),
    ];
    // The two boundary cases exercise one and two padding blocks; expected values are checked
    // against the platform digest implementation below so this test never embeds a hand-rolled hash.
    for (const text of vectors) {
      const file = new File([text], "vector.txt");
      expect(await hashFile(file)).toBe(
        [...new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)))]
          .map((byte) => byte.toString(16).padStart(2, "0"))
          .join(""),
      );
    }
  });

  test("upload reads an oversized file only through bounded slices", async () => {
    const size = 10 * 1024 * 1024 + 5;
    let wholeRead = false;
    const file = {
      name: "large.txt",
      type: "text/plain",
      size,
      arrayBuffer: async () => {
        wholeRead = true;
        throw new Error("whole-file read");
      },
      slice: (start: number, end: number) =>
        new Blob([new Uint8Array(Math.max(0, Math.min(end, size) - start)).fill(97)], { type: "text/plain" }),
    } as unknown as File;
    const chunks: { offset: number; data: string }[] = [];
    const client = {
      call: async (method: string, params: Record<string, unknown>) => {
        if (method !== "cmux.home.attachmentUpload") throw new Error(`unexpected ${method}`);
        if (params.op === "begin") return { upload: "u1", needs: ["original"] };
        if (params.op === "chunk") {
          chunks.push({ offset: params.offset as number, data: params.data as string });
          return null;
        }
        if (params.op === "commit") return { stored: undefined };
        throw new Error(`unexpected op ${String(params.op)}`);
      },
    };
    const progress: number[] = [];
    await new AttachmentService(client as never).upload("conversation", file, (next) => progress.push(next.sent));
    expect(wholeRead).toBe(false);
    expect(chunks.length).toBeGreaterThan(10);
    expect(chunks[0]!.offset).toBe(0);
    expect(chunks[1]!.offset).toBe(1024 * 1024);
    expect(atob(chunks[0]!.data).length).toBe(1024 * 1024);
    expect(progress.at(-1)).toBe(size);
  });

  test("skips image preview decoding for a decompression bomb", async () => {
    let decodes = 0;
    (globalThis as { createImageBitmap?: unknown }).createImageBitmap = async () => {
      decodes += 1;
      throw new Error("bomb must not be decoded");
    };
    const header = new Uint8Array(24);
    header.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a], 0);
    new DataView(header.buffer).setUint32(16, 0xffff_ffff);
    new DataView(header.buffer).setUint32(20, 0xffff_ffff);
    const file = new File([header], "bomb.png", { type: "image/png" });
    const client = {
      call: async (method: string, params: Record<string, unknown>) => {
        if (method !== "cmux.home.attachmentUpload") throw new Error(`unexpected ${method}`);
        if (params.op === "begin") return { upload: "u1", needs: ["original"] };
        if (params.op === "chunk") return null;
        if (params.op === "commit") return { stored: undefined };
        throw new Error(`unexpected op ${String(params.op)}`);
      },
    };
    await new AttachmentService(client as never).upload("conversation", file, () => {});
    expect(decodes).toBe(0);
  });

  test("keeps a bounded HEIC preview fallback", async () => {
    let options: unknown;
    (globalThis as { createImageBitmap?: unknown }).createImageBitmap = async (_file: Blob, next?: unknown) => {
      options = next;
      return { width: 720, height: 720, close() {} };
    };
    const file = new File([new Uint8Array([1, 2, 3])], "photo.heic", { type: "image/heic" });
    const client = {
      call: async (method: string, params: Record<string, unknown>) => {
        if (method !== "cmux.home.attachmentUpload") throw new Error(`unexpected ${method}`);
        if (params.op === "begin") return { upload: "u1", needs: ["original"] };
        if (params.op === "chunk") return null;
        if (params.op === "commit") return { stored: undefined };
        throw new Error(`unexpected op ${String(params.op)}`);
      },
    };
    await new AttachmentService(client as never).upload("conversation", file, () => {});
    expect(options).toMatchObject({ resizeWidth: 720, resizeHeight: 720, resizeQuality: "low" });
  });
});
