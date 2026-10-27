import { describe, expect, test } from "bun:test";
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

  test("an empty file is refused but a file beyond the former cap is accepted", () => {
    expect(refusal(new File([], "empty.txt"))).toBe("size");
    expect(refusal({ size: 100 * 1024 * 1024 + 1 } as File)).toBeUndefined();
  });

  test("streamed hashes match SHA-256 across padding boundaries", async () => {
    const vectors = [...Array.from({ length: 129 }, (_, n) => "a".repeat(n)), "a".repeat(3 * 1024 * 1024 + 127)];
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
        new Blob([new Uint8Array(Math.max(0, Math.min(size, end) - start)).fill(97)], {
          type: "text/plain",
        }),
    } as unknown as File;
    let received = 0;
    let chunks = 0;
    const client = {
      call: async (method: string, params: Record<string, unknown>) => {
        if (method !== "cmux.home.attachmentUpload") throw new Error(`unexpected ${method}`);
        if (params.op === "begin") return { upload: "u1", needs: ["original"] };
        if (params.op === "chunk") {
          const decoded = atob(params.data as string);
          expect(params.offset).toBe(received);
          expect(decoded.length).toBe(Math.min(1024 * 1024, size - received));
          expect(decoded).toBe("a".repeat(decoded.length));
          received += decoded.length;
          chunks += 1;
          return null;
        }
        if (params.op === "commit") return { stored: undefined };
        throw new Error(`unexpected op ${String(params.op)}`);
      },
    };
    const progress: number[] = [];
    await new AttachmentService(client as never).upload("conversation", file, (next) => progress.push(next.sent));
    expect(wholeRead).toBe(false);
    expect(chunks).toBe(11);
    expect(received).toBe(size);
    expect(progress.at(-1)).toBe(size);
  });

  test("hash cancellation during a read stops before the next slice", async () => {
    const controller = new AbortController();
    let reads = 0;
    const file = {
      size: 2 ** 40,
      slice: (_start: number, end: number) => ({
        arrayBuffer: async () => {
          reads += 1;
          expect(end).toBeLessThanOrEqual(64 * 1024);
          controller.abort();
          return new ArrayBuffer(64 * 1024);
        },
      }),
    } as unknown as File;
    await expect(hashFile(file, controller.signal)).rejects.toThrow();
    expect(reads).toBe(1);
  });

  test("upload cancellation releases its slot before sending another chunk", async () => {
    const controller = new AbortController();
    const operations: string[] = [];
    const client = {
      call: async (_method: string, params: Record<string, unknown>) => {
        operations.push(params.op as string);
        if (params.op === "begin") return { upload: "u1", needs: ["original"] };
        if (params.op === "chunk") controller.abort();
        return null;
      },
    };
    await expect(
      new AttachmentService(client as never).upload(
        "conversation",
        new File([new Uint8Array(1024 * 1024 + 1)], "binary"),
        () => {},
        controller.signal,
      ),
    ).rejects.toThrow();
    expect(operations).toEqual(["begin", "chunk", "cancel"]);
  });
});
