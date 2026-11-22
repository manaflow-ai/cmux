import { expect, test } from "bun:test";
import { createStrings, formatString } from "./i18n";

// A plural string is `key#<category>` for every category, in every locale (gen-strings.mjs).
const table = {
  en: {
    "updates.available#one": "%@ update available",
    "updates.available#other": "%@ updates available",
    "updates.version": "Version %@",
  },
  ru: {
    "updates.available#one": "Доступно обновление: %@",
    "updates.available#few": "Доступно обновления: %@",
    "updates.available#many": "Доступно обновлений: %@",
    "updates.available#other": "Доступно обновлений: %@",
    "updates.version": "Версия %@",
  },
};

test("a plural string takes the form its count picks, one for one", () => {
  const strings = createStrings(table, ["en"]);
  expect(strings.format("updates.available", "1")).toBe("1 update available");
  expect(strings.format("updates.available", "3")).toBe("3 updates available");
  expect(strings.format("updates.available", "0")).toBe("0 updates available");
});

test("a language with more forms picks among them", () => {
  const strings = createStrings(table, ["ru"]);
  expect(strings.format("updates.available", "1")).toBe("Доступно обновление: 1");
  expect(strings.format("updates.available", "3")).toBe("Доступно обновления: 3");
  expect(strings.format("updates.available", "5")).toBe("Доступно обновлений: 5");
  expect(strings.format("updates.available", "21")).toBe("Доступно обновление: 21");
});

test("a string with no plural forms formats as before", () => {
  expect(createStrings(table, ["ru"]).format("updates.version", "1.2.0")).toBe("Версия 1.2.0");
});

test("a language whose catalog gave it no plural forms uses its plain string, not English", () => {
  const plain = { ...table, ja: { "updates.available": "%@件のアップデートがあります", "updates.version": "v%@" } };
  expect(createStrings(plain, ["ja"]).format("updates.available", "1")).toBe("1件のアップデートがあります");
});

// Xcode's catalog compiler refuses a plural variation without an integer specifier, so a plural
// catalog string uses %lld (store.updates.available after #30288 broke the package build).
test("integer specifiers format like %@, in order and by position", () => {
  expect(formatString("%lld updates available", ["3"])).toBe("3 updates available");
  expect(formatString("يتوفر تحديثان (%lld)", ["2"])).toBe("يتوفر تحديثان (2)");
  expect(formatString("%d of %ld, %@", ["1", "2", "x"])).toBe("1 of 2, x");
  expect(formatString("%2$lld before %1$@", ["a", "9"])).toBe("9 before a");
  expect(formatString("100%% of %lld", ["4"])).toBe("100% of 4");
});
