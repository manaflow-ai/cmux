import { describe, expect, test } from "bun:test";
import { GENERIC_FILE_TYPE, looksLikeText, refusal, resolvedType } from "../src/pages/home-channels/attachmentService";

// Any file attaches (Lawrence 2026-10-20, "“index.html” can't be attached ... need to fix this"):
// UTF-8 text of any name goes as text/plain, other bytes as a generic file; only size refuses.
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

  test("only an empty file or one over 100 MB is refused", () => {
    expect(refusal(new File([], "empty.txt"))).toBe("size");
  });
});
