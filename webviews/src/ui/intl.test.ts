import { afterEach, expect, test } from "bun:test";
import { intl, resetIntlCacheForTests } from "./intl";

afterEach(() => resetIntlCacheForTests());

test("one formatter per kind, locale and options", () => {
  const a = intl.NumberFormat("en-US", { notation: "compact" });
  expect(intl.NumberFormat("en-US", { notation: "compact" })).toBe(a);
  expect(intl.NumberFormat("de-DE", { notation: "compact" })).not.toBe(a);
  expect(intl.NumberFormat("en-US")).not.toBe(a);
  expect(intl.DateTimeFormat("en-US", { notation: "compact" } as Intl.DateTimeFormatOptions)).not.toBe(a);
});

test("formats as a fresh constructor would", () => {
  const options: Intl.DateTimeFormatOptions = { year: "numeric", month: "short", day: "numeric", timeZone: "UTC" };
  const at = Date.UTC(2026, 9, 20, 22, 16);
  expect(intl.DateTimeFormat("de-DE", options).format(at)).toBe(new Intl.DateTimeFormat("de-DE", options).format(at));
  expect(intl.NumberFormat("en-US", { maximumFractionDigits: 1 }).format(1234.56)).toBe("1,234.6");
  expect(intl.ListFormat("en", { type: "conjunction" }).format(["a", "b", "c"])).toBe("a, b, and c");
});

test("an undefined option and a missing one share a formatter", () => {
  expect(intl.DateTimeFormat("en-US", { month: "short", year: undefined })).toBe(
    intl.DateTimeFormat("en-US", { month: "short" }),
  );
});

test("a bad language tag still throws, so callers' fallbacks run", () => {
  expect(() => intl.DateTimeFormat("not a tag!!", {})).toThrow(RangeError);
});

test("the cache starts over after a minute, so a zone or language change shows", () => {
  const realNow = Date.now;
  let now = 1_000_000;
  Date.now = () => now;
  try {
    const a = intl.NumberFormat("en-US");
    now += 59_000;
    expect(intl.NumberFormat("en-US")).toBe(a);
    now += 2_000;
    expect(intl.NumberFormat("en-US")).not.toBe(a);
  } finally {
    Date.now = realNow;
  }
});
