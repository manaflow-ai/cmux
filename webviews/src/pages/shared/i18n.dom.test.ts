import { afterEach, expect, test } from "bun:test";
import { Window } from "happy-dom";
import { readFileSync } from "node:fs";
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

test("explicit page locale replaces RTL metadata", () => {
  const window = new Window();
  Object.defineProperty(globalThis, "document", { configurable: true, value: window.document });
  for (const language of ["ar", "en", "ja"]) {
    createStrings({ en: {}, ar: {}, ja: {} }, [language]);
    expect(window.document.documentElement.lang).toBe(language);
    expect(window.document.documentElement.dir).toBe(language === "ar" ? "rtl" : "ltr");
  }
});

test("RTL diff chrome preserves the physical code and sidebar layout", () => {
  const window = new Window();
  Object.defineProperty(globalThis, "document", { configurable: true, value: window.document });
  const style = window.document.createElement("style");
  style.textContent = readFileSync(new URL("../../styles.css", import.meta.url), "utf8");
  window.document.head.append(style);
  window.document.body.innerHTML =
    '<div id="content"><main id="viewer"><diffs-container></diffs-container></main><aside id="files-sidebar"><div id="file-list"><file-tree-container></file-tree-container></div></aside></div>';
  createStrings({ en: {}, ar: {} }, ["ar"]);
  // happy-dom does not implement the user-agent dir attribute presentation hint.
  window.document.documentElement.style.direction = "rtl";
  const direction = (selector: string) => window.getComputedStyle(window.document.querySelector(selector)!).direction;
  expect(direction("#content")).toBe("ltr");
  expect(direction("#viewer")).toBe("rtl");
  expect(direction("#files-sidebar")).toBe("rtl");
  expect(direction("diffs-container")).toBe("ltr");
  expect(direction("file-tree-container")).toBe("ltr");
});
