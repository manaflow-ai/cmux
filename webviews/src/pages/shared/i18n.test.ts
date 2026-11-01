import { expect, test } from "bun:test";
import { createStrings } from "./i18n";

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
