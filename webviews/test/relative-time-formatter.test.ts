// Constructor counts guard the mounted-row cost; real ICU supplies the expected wording.
import { expect, test } from "bun:test";
import { relativeTime } from "../src/agent-session/acpmux/conversation/relativeTime";

const NOW = Date.UTC(2026, 10, 3, 12);
const MINUTE = 60_000;
const NativeRelativeTimeFormat = Intl.RelativeTimeFormat;

// No await inside the replacement's lifetime: another test cannot observe a patched Intl
// constructor, and a failed assertion still restores it. The proxy constructs real formatters.
function countConstructors(run: (locales: unknown[]) => void): void {
  const saved = Intl.RelativeTimeFormat;
  const descriptor = Object.getOwnPropertyDescriptor(Intl, "RelativeTimeFormat")!;
  const locales: unknown[] = [];
  const counted = new Proxy(saved, {
    construct(target, args, newTarget) {
      locales.push(args[0]);
      return Reflect.construct(target, args, newTarget);
    },
  });
  Object.defineProperty(Intl, "RelativeTimeFormat", { ...descriptor, value: counted });
  try {
    run(locales);
  } finally {
    Object.defineProperty(Intl, "RelativeTimeFormat", descriptor);
  }
}

test("mounted timestamp labels reuse one formatter for a supported explicit locale", () => {
  // Evict any previous supported locale without adding a product-only cache reset seam.
  relativeTime(NOW - MINUTE, NOW, "de-DE");
  const expected = new NativeRelativeTimeFormat("en-US", { numeric: "auto" }).format(-2, "minute");
  countConstructors((locales) => {
    for (let row = 0; row < 40; row += 1) {
      expect(relativeTime(NOW - 2 * MINUTE, NOW, "en-US")).toBe(expected);
      expect(relativeTime(NOW, NOW, "en-US")).toBe("just now");
    }
    expect(locales).toEqual(["en-US"]);
  });
});

test("switching supported locales replaces the formatter instead of retaining a locale map", () => {
  relativeTime(NOW - MINUTE, NOW, "ja-JP");
  countConstructors((locales) => {
    for (const locale of ["en-US", "de-DE", "en-US"]) {
      const expected = new NativeRelativeTimeFormat(locale, { numeric: "auto" }).format(-1, "day");
      expect(relativeTime(NOW - 24 * 60 * MINUTE, NOW, locale)).toBe(expected);
      expect(relativeTime(NOW - 24 * 60 * MINUTE, NOW, locale)).toBe(expected);
    }
    // Returning to en-US constructs again: only the last supported locale is retained.
    expect(locales).toEqual(["en-US", "de-DE", "en-US"]);
  });
});

test("default and unsupported locales stay uncached without evicting the supported locale", () => {
  const unsupported = "qaa-x-private";
  expect(NativeRelativeTimeFormat.supportedLocalesOf(unsupported)).toEqual([]);
  relativeTime(NOW - MINUTE, NOW, "en-US");
  countConstructors((locales) => {
    for (const locale of [undefined, unsupported]) {
      const expected = new NativeRelativeTimeFormat(locale, { numeric: "auto" }).format(-1, "minute");
      expect(relativeTime(NOW - MINUTE, NOW, locale)).toBe(expected);
      expect(relativeTime(NOW - MINUTE, NOW, locale)).toBe(expected);
    }
    expect(relativeTime(NOW, NOW, "en-US")).toBe("just now");
    expect(locales).toEqual([undefined, undefined, unsupported, unsupported]);
  });
});

test("cached formatters preserve future times and the rounded just-now boundary in each language", () => {
  for (const locale of ["en-US", "de-DE"]) {
    const words = new NativeRelativeTimeFormat(locale, { numeric: "auto" });
    const now = words.resolvedOptions().locale.toLowerCase().startsWith("en") ? "just now" : words.format(0, "second");
    // Warm the cache, then cross both branches of relativeTime without changing its locale.
    relativeTime(NOW - MINUTE, NOW, locale);
    for (const at of [NOW + 10 * MINUTE, NOW, NOW - 59_500]) expect(relativeTime(at, NOW, locale)).toBe(now);
    expect(relativeTime(NOW - 59_501, NOW, locale)).toBe(words.format(-1, "minute"));
    expect(relativeTime(NOW - MINUTE, NOW, locale)).toBe(words.format(-1, "minute"));
  }
});

test("a populated formatter cache preserves malformed-locale and nonfinite-age errors", () => {
  relativeTime(NOW - MINUTE, NOW, "en-US");
  expect(() => new NativeRelativeTimeFormat("en_US", { numeric: "auto" })).toThrow(RangeError);
  for (const at of [NOW, NOW - MINUTE]) expect(() => relativeTime(at, NOW, "en_US")).toThrow(RangeError);
  const words = new NativeRelativeTimeFormat("en-US", { numeric: "auto" });
  for (const at of [NaN, -Infinity]) {
    expect(() => words.format(at, "year")).toThrow(RangeError);
    expect(() => relativeTime(at, NOW, "en-US")).toThrow(RangeError);
  }
  // Throwing calls neither replace the valid locale nor corrupt its next output.
  countConstructors((locales) => {
    expect(relativeTime(NOW - MINUTE, NOW, "en-US")).toBe(words.format(-1, "minute"));
    expect(locales).toEqual([]);
  });
});
