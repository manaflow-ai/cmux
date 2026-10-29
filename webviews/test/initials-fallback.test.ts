import { expect, test } from "bun:test";
import { graphemePrefix, initials } from "../src/ui/initials";

test("flag initials keep the complete flag with grapheme support", () => {
  expect(graphemePrefix("🇯🇵 Japan", 1)).toBe("🇯🇵");
  expect(initials("🇯🇵 Japan")).toBe("🇯🇵J");
});

test("initials import and preserve code points without Intl.Segmenter", async () => {
  const descriptor = Object.getOwnPropertyDescriptor(Intl, "Segmenter")!;
  let fallback: typeof import("../src/ui/initials");
  try {
    Object.defineProperty(Intl, "Segmenter", { ...descriptor, value: undefined });
    const modulePath = "../src/ui/initials.ts?without-segmenter";
    fallback = await import(modulePath);
  } finally {
    Object.defineProperty(Intl, "Segmenter", descriptor);
  }
  expect(fallback.initials("Ana Ruiz")).toBe("AR");
  expect(fallback.initials("🦊 Fox")).toBe("🦊F");
  expect(fallback.initials("𠮷田")).toBe("𠮷田");
  expect(fallback.initials("   ")).toBe("?");
  expect(fallback.graphemePrefix("🦊 Fox", 1)).toBe("🦊");
  // The fallback cannot join graphemes, but it never returns half a surrogate pair.
  expect(fallback.graphemePrefix("🇯🇵 Japan", 1)).toBe("🇯");
});
