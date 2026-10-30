import { expect, test } from "bun:test";
import { initials as appInitials } from "../src/pages/apps/model";
import { graphemePrefix, initials } from "../src/ui/initials";

test("flag initials keep the complete flag with grapheme support", () => {
  expect(graphemePrefix("🇯🇵 Japan", 1)).toBe("🇯🇵");
  expect(initials("🇯🇵 Japan")).toBe("🇯🇵J");
});

test("initials import and preserve code points without Intl.Segmenter", async () => {
  const descriptor = Object.getOwnPropertyDescriptor(Intl, "Segmenter");
  let fallback: typeof import("../src/ui/initials");
  try {
    Object.defineProperty(Intl, "Segmenter", {
      ...(descriptor ?? { configurable: true, writable: true }),
      value: undefined,
    });
    const modulePath = "../src/ui/initials.ts?without-segmenter";
    fallback = await import(modulePath);
  } finally {
    if (descriptor) Object.defineProperty(Intl, "Segmenter", descriptor);
    else Reflect.deleteProperty(Intl, "Segmenter");
  }
  expect(fallback.initials("Ana Ruiz")).toBe("AR");
  expect(fallback.initials("🦊 Fox")).toBe("🦊F");
  expect(fallback.initials("𠮷田")).toBe("𠮷田");
  expect(fallback.initials("   ")).toBe("?");
  expect(fallback.graphemePrefix("🦊 Fox", 1)).toBe("🦊");
  // The fallback cannot join graphemes, but it never returns half a surrogate pair.
  expect(fallback.graphemePrefix("🇯🇵 Japan", 1)).toBe("🇯");
});

test("initials import when Intl.Segmenter construction throws", async () => {
  const descriptor = Object.getOwnPropertyDescriptor(Intl, "Segmenter");
  let fallback: typeof import("../src/ui/initials");
  try {
    Object.defineProperty(Intl, "Segmenter", {
      ...(descriptor ?? { configurable: true, writable: true }),
      value: class {
        constructor() {
          throw new Error("Segmenter unavailable");
        }
      },
    });
    const modulePath = "../src/ui/initials.ts?throwing-segmenter";
    fallback = await import(modulePath);
  } finally {
    if (descriptor) Object.defineProperty(Intl, "Segmenter", descriptor);
    else Reflect.deleteProperty(Intl, "Segmenter");
  }
  expect(fallback.initials("🦊 Fox")).toBe("🦊F");
  expect(fallback.graphemePrefix("𠮷田", 1)).toBe("𠮷");
});

test("App Store fallback icons keep whole characters (cmuxterm-hq#4380)", () => {
  expect(appInitials("😀 Apps")).toBe("😀A");
  expect(appInitials("𠮷 Tools")).toBe("𠮷T");
  expect(appInitials("A😀")).toBe("A😀");
  expect(appInitials("GitHub PRs")).toBe("GP");
  expect(appInitials("Caffeinate")).toBe("CA");
  expect(appInitials("   ")).toBe("?");
});
