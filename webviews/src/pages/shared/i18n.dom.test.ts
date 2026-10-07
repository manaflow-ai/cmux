import { afterEach, expect, test } from "bun:test";
import { Window } from "happy-dom";
import { createStrings } from "./i18n";

const original = Object.getOwnPropertyDescriptor(globalThis, "document");
afterEach(() => {
  if (original) Object.defineProperty(globalThis, "document", original);
  else Reflect.deleteProperty(globalThis, "document");
});

test("page locale sets document language and direction, including language changes", () => {
  const window = new Window();
  Object.defineProperty(globalThis, "document", { configurable: true, value: window.document });
  Object.defineProperty(window.navigator, "languages", { configurable: true, value: ["ar"] });
  createStrings({ en: {}, ar: {}, ja: {} });
  expect(window.document.documentElement.lang).toBe("ar");
  expect(window.document.documentElement.dir).toBe("rtl");
  for (const language of ["en", "ja", "ar"]) {
    Object.defineProperty(window.navigator, "languages", { configurable: true, value: [language] });
    window.dispatchEvent(new window.Event("languagechange"));
    expect(window.document.documentElement.lang).toBe(language);
    expect(window.document.documentElement.dir).toBe(language === "ar" ? "rtl" : "ltr");
  }
});
